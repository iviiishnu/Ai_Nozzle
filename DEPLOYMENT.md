# Crop Scanner — Setup, Deployment & Blynk IoT

How the parts connect:

```
Tablet (Flutter app) ──USB/OTG── webcam
   │  photo / live frames
   │
   ├─ on-device TFLite model ──────────────┐   (default, works offline)
   └─ HTTP → Spring :8000 → Python ML :5010 ┤   (server mode, falls back to tablet)
                                            ▼
                                   result: disease, damage %
                                            │  HTTPS (Blynk HTTP API)
                                            ▼
                               Blynk Cloud  V4 = damage %
                                            │
                                            ▼
                     ESP32 → L293D → 12 V motor (sprays if damage ≥ 15 %)
                     ESP32 → Blynk V5 = motor running (shown in the app)
```

No IPs, tokens, or passwords are in the source code. Each part reads them from a local, git-ignored file:

| Part | Config file (copy from) | What goes in it |
|---|---|---|
| Python ML server | `ai_service/.env` (`.env.example`) | port, model path, thresholds (all optional) |
| Spring backend | environment variables (see `application.properties`) | `SERVER_PORT`, `AI_SERVICE_URL`, `MAX_UPLOAD_SIZE` |
| Flutter app | `flutter_app/config/app_config.json` (`app_config.example.json`) | default server URL, Blynk server + token |
| ESP32 | `ardunio/esp32_motor_control/secrets.h` (`secrets.example.h`) | WiFi, Blynk template ID + token |

The app also has a **Settings** screen (⚙ on the analyzer page) to change the server URL, Blynk server/token and live-scan interval on the tablet without rebuilding. **Test connections** checks both.

Decision thresholds are the same everywhere:

| Damage % (share of leaf that isn't green) | Severity | Spray |
|---|---|---|
| < 15 | Low | no |
| 15 – 34 | Medium | 3 s (15–24) / 5 s (25–34) |
| 35 – 49 | High | 7 s |
| ≥ 50 | High | 10 s |

If you change them, update `ai_service/.env` (`DAMAGE_MEDIUM`, `DAMAGE_HIGH`), `flutter_app/lib/config.dart` and the `#define`s at the top of the firmware.

---

## 1. Backend (PC or server)

```bash
# Python ML server
cd ai_service
python3 -m venv venv && venv/bin/pip install -r requirements.txt
cp .env.example .env            # optional
venv/bin/python farm_app.py     # Waitress on 0.0.0.0:5010

# Spring backend (Java 17)
cd spring_backend/spring_backend_fresh/spring_backend
./mvnw spring-boot:run          # :8000, forwards to http://127.0.0.1:5010
# production:
./mvnw -DskipTests package
AI_SERVICE_URL=http://127.0.0.1:5010 java -jar target/spring_backend-0.0.1-SNAPSHOT.jar
```

Check it's working: `curl http://<pc-ip>:8000/api/crop/health` should return `"status":"ok"`.

If there's no trained `.h5` model, the ML server uses `models/crop_model_float16.tflite`, the same model the app ships.

The tablet must reach `<pc-ip>:8000`, so allow the port in the PC firewall.

In Kiro/VS Code: **Tasks: Run Task → Start Backend (ML + Spring)**.

## 2. Tablet app

```bash
cd flutter_app
cp config/app_config.example.json config/app_config.json   # set BACKEND_URL to http://<pc-ip>:8000
adb pair <ip:pair-port> <code>      # Wireless debugging → Pair device with pairing code (first time)
adb connect <ip:port>               # Wireless debugging main screen
flutter run --dart-define-from-file=config/app_config.json
# release APK:
flutter build apk --release --dart-define-from-file=config/app_config.json
```

Using the USB/OTG webcam:
- **Camera** button → in-app camera; the USB webcam is picked automatically (dropdown at the top right to switch).
- **Live Camera** button → preview plus **Scan now** / **Auto-scan every N s**. Each result is sent to the sprayer.
- If an orange bar says *USB webcam not detected*, Android isn't exposing the webcam to apps. The line `📷 Cameras found:` in the `flutter run` log lists what the tablet reports.

## 3. Blynk IoT (connecting the hardware)

### 3.1 Create the template (Blynk Console → Developer Zone → My Templates → New)

- Name: `ESP32 Motor Control`, Hardware: **ESP32**, Connection: **WiFi**.
- **Datastreams** tab → add these **Virtual Pin** datastreams (all *Integer*):

| Pin | Name | Min–Max | Default | Written by |
|---|---|---|---|---|
| V0 | Manual Forward | 0–1 | 0 | dashboard button |
| V1 | Manual Reverse | 0–1 | 0 | dashboard button |
| V2 | Stop | 0–1 | 0 | dashboard button |
| V4 | Damage % | 0–100 | 0 | **app** |
| V5 | Motor Status | 0–1 | 0 | **ESP32** |

- **Web Dashboard / Mobile Dashboard** (optional): buttons (Push mode) for V0/V1/V2, a gauge for V4, an LED for V5.
- Save. Copy `BLYNK_TEMPLATE_ID` and `BLYNK_TEMPLATE_NAME` from *Firmware configuration*.

### 3.2 Create the device

- Devices → **New Device → From template** → pick the template.
- Open the device → **Device info** → copy the **Auth Token**. The ESP32 **and** the app use this token.
- Note the **server region** shown in the device info / URL (e.g. `blynk.cloud`, `blr1.blynk.cloud`, `sgp1.blynk.cloud`). If the app's *Test connections* reports "Blynk: failed", set this host as the Blynk server.

### 3.3 Flash the ESP32

1. Wire it as in [connection_setup.md](connection_setup.md): GPIO27 → IN1, GPIO26 → IN2, GPIO14 → ENA, common GND with the 12 V supply.
2. `cp ardunio/esp32_motor_control/secrets.example.h ardunio/esp32_motor_control/secrets.h` and fill in the template ID, template name, auth token, and **2.4 GHz** WiFi name/password.
3. Arduino IDE: install *esp32 by Espressif* (Boards Manager) and *Blynk* (Library Manager). Board: **ESP32 Dev Module**. Upload, then open Serial Monitor at 115200.
   Or in Kiro: **Tasks → 5b. ESP32: upload firmware (USB)**.
4. Serial should show `Connected. IP: …` and the device turns **Online** in Blynk Console.

### 3.4 Connect the app

In the app → ⚙ Settings → Blynk server + the same auth token (or put them in `config/app_config.json` before building) → **Test connections** should show `Blynk: OK`.

### 3.5 End-to-end check

1. Scan a leaf. The result card shows *Sent NN% to sprayer*.
2. Blynk Console → device → V4 shows NN.
3. If NN ≥ 15, the motor runs forward for the band's time, reverses for 1 s to close the nozzle, then stops. V5 goes 1 → 0, and the app's *Sprayer* card shows *Motor running* → *Motor stopped*.
4. Below 15 %, the ESP32 logs `Below spray threshold — no spray`.

Safety built into the firmware:
- The motor is off at power-up (the old boot-time test run is disabled; enable it with `RUN_SELF_TEST_ON_BOOT 1` for bench tests).
- Scans that arrive while the motor is busy, or within 5 s of the last spray, are ignored.
- Manual forward/reverse stops by itself after 15 s.
