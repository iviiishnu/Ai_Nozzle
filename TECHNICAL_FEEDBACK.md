# 🔍 Crop Scanner — Technical Feedback & Improvement Roadmap

> Honest analysis of every component. Updated to reflect the current codebase state after the major refactor. Read this before making any further changes — it tells you what's done, what's broken, and what to do next.

---

## Table of Contents

1. [What Was Fixed in the Refactor](#1-what-was-fixed-in-the-refactor)
2. [Backend (Spring Boot) — Current Issues](#2-backend-spring-boot--current-issues)
3. [Flutter App — Current Issues](#3-flutter-app--current-issues)
4. [AI / ML Server — Current Issues](#4-ai--ml-server--current-issues)
5. [IoT Layer (ESP32 + Blynk) — Current Issues](#5-iot-layer-esp32--blynk--current-issues)
6. [Networking Analysis](#6-networking-analysis)
7. [Improvement Roadmap](#7-improvement-roadmap)
8. [Deployment Plan](#8-deployment-plan)

---

## 1. What Was Fixed in the Refactor

These issues from the previous version of this document are now resolved.

### ✅ Hardcoded absolute paths — FIXED
All `D:\crop-scanner\...` paths in `farm_app.py`, `inference.py`, `train_model.py`, `evalute_model.py`, and `convert_tflite.py` now use:
```python
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(BASE_DIR, "models", "crop_model_best.h5")
```
Still hardcoded in: `damage_estimator.py`, `dataset_utils.py`, `covert.py` (unused files).

### ✅ `debug=True` — FIXED
Now reads from environment:
```python
debug_mode = os.getenv("FLASK_DEBUG", "false").lower() == "true"
app.run(host="0.0.0.0", port=port, debug=debug_mode)
```

### ✅ Wrong damage_percent formula — FIXED
Old: `(1 - confidence) * 100` — this was just inverse confidence.  
New: entropy-based formula in `inference.py`:
```python
ent = scipy_entropy(preds)
max_entropy = np.log(num_classes)
entropy_ratio = ent / max_entropy
confidence_weight = 0.5 + (1.0 - confidence) * 0.5
damage = entropy_ratio * 100 * confidence_weight
```
Now returns a meaningful number. High confidence + clear disease = moderate-high damage. Spread predictions = higher damage (caution). Capped at 95%.

### ✅ Path traversal vulnerability — FIXED
UUID filenames, file type allowlist, always-delete in `finally`:
```python
safe_name = f"{uuid.uuid4().hex}{original_ext}"
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
# finally: os.remove(file_path)
```

### ✅ Model load crash on startup — FIXED
`inference.py → load_keras_model()` wraps load in try/except, runs warm-up inference, calls `sys.exit(1)` on failure with a clear message.

### ✅ Evaluation normalization — FIXED
`evalute_model.py` now uses `/255.0` to match training normalization (was `/127.5 - 1.0`). All accuracy metrics are now reliable.

### ✅ Uploaded files never deleted — FIXED
`finally` block in `farm_app.py` always runs `os.remove(file_path)` after each request.

### ✅ No health endpoint — FIXED
`GET /health` returns `{"status": "ok", "model_loaded": true, "classes": [...], "num_classes": 7}`.

### ✅ No file type validation — FIXED
Extension validated against allowlist before saving.

### ✅ No request size limit — FIXED
`app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024`.

### ✅ TFLite unused in Flutter — FIXED
`TfliteService` is now wired and functional. On-device inference works. Toggled with phone/cloud icon in app bar. Automatic bidirectional fallback implemented.

### ✅ `usb_serial` unused dependency — FIXED
Removed from `pubspec.yaml`.

### ✅ No motor status feedback from ESP32 — FIXED
ESP32 now writes `1`/`0` to V5 on motor state changes. Flutter reads V5 via `blynk.getMotorStatus()` every 2 seconds.

### ✅ Single-frame prediction instability — FIXED
`predict_with_tta()` averages 5 augmented variants. Falls back to `predict_single()` if TTA fails.

### ✅ No confidence threshold — FIXED
Below 50% confidence → returns `"Uncertain"` with user message instead of a wrong disease label.

### ✅ Leaf detection misses diseased leaves — FIXED
HSV mask now includes yellow-brown range for diseased/yellowing leaves. Threshold raised 0.02 → 0.04.

### ✅ Training instability — FIXED
`train_model.py` fixes: LR 1e-3 → 3e-4, fine-tune only last 15 layers, class weight cap 2.0, gradient clipping, label smoothing 0.05, fine-tune gating at 50% Phase 1 accuracy.

---

## 2. Backend (Spring Boot) — Current Issues

### Current behavior
- `GET /api/crop/test` → health check string
- `POST /api/crop/analyze` → receives image from Flutter, forwards to Python at `http://127.0.0.1:5010/api/crop/analyze`, returns raw response

### ❌ No error handling when Python server is down
```java
// CropService.java
ResponseEntity<String> response = restTemplate.postForEntity(aiUrl, requestEntity, String.class);
return response.getBody();
```
If Python is down, `ResourceAccessException` is thrown and Flutter gets a 500 with a Java stack trace.

**Fix:**
```java
try {
    ResponseEntity<String> response = restTemplate.postForEntity(aiUrl, requestEntity, String.class);
    return response.getBody();
} catch (ResourceAccessException e) {
    throw new RuntimeException("AI service is unavailable. Try again shortly.");
} catch (HttpClientErrorException e) {
    throw new RuntimeException("AI service returned: " + e.getStatusCode());
}
```

### ❌ Python server URL is hardcoded
```java
String aiUrl = "http://127.0.0.1:5010/api/crop/analyze";
```
Moving Python to another machine requires a code change and recompile.

**Fix — `application.properties`:**
```properties
ai.service.url=http://127.0.0.1:5010
spring.servlet.multipart.max-file-size=10MB
spring.servlet.multipart.max-request-size=10MB
```
```java
@Value("${ai.service.url}")
private String aiServiceUrl;
```

### ❌ Spring Boot is still a pass-through proxy
`CropService.java` does nothing except forward the image. No auth, no logging, no database, no enrichment. Either give it real work or remove it and have Flutter call Python directly.

**What real work looks like:**
- Call `GET /health` before forwarding (check Python is alive)
- Store scan history in MySQL (`ScanRecord` with timestamp, disease, confidence, damage, GPS)
- Add JWT authentication
- Enrich response with fertilizer recommendation from `configs/fertilizer.json`
- Call Blynk REST API directly (remove that responsibility from Flutter)

### ❌ `AIServiceClient.java` and `CropAnalysisResult.java` are dead code
WebClient-based alternative never used. DTO never populated. Remove both or implement them.

### ❌ MySQL configured but unused
`pom.xml` includes `mysql-connector-j`. Without a running MySQL instance, Spring Boot may print connection errors at startup. Either wire up JPA + a `ScanRecord` entity or remove the dependency.

---

## 3. Flutter App — Current Issues

### What works well now
- TFLite on-device inference fully wired with bidirectional fallback
- Inference source badge with timing
- Motor status from V5 (real feedback, not guessed)
- Deduplication guard on Blynk sends
- Clean widget separation (loading overlay, image picker, image preview)
- Error handling covers all network exception types

### ❌ Blynk auth token hardcoded in source — in THREE places
```dart
// crop_analyzer_page.dart
final BlynkService blynk = BlynkService("rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM");

// live_camera_page.dart
final BlynkService blynk = BlynkService("rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM");

// blynk_screen.dart
blynk = BlynkService("YOUR_BLYNK_AUTH_TOKEN");  // placeholder
```
The real token is committed to git. Anyone with repo access can control the ESP32.

**Fix:** Use `flutter_dotenv` or `--dart-define`:
```bash
flutter run --dart-define=BLYNK_TOKEN=your_token_here
```
```dart
const String blynkToken = String.fromEnvironment('BLYNK_TOKEN');
```

### ❌ Three hardcoded IPs in config.dart
```dart
const String BASE_URL = "http://10.85.245.16:8000/";
const String WEBCAM_SERVER_URL = "http://10.85.245.16:5011";
const String ML_SERVER_URL = "http://10.85.245.16:5010";
```
Must rebuild the app every time you change networks. This is the #1 cause of "it worked yesterday" failures.

### ❌ No state management — raw setState throughout
`CropAnalyzerPage` is a 300+ line `StatefulWidget` mixing API calls, timer management, Blynk polling, and UI. Hard to test and prone to `setState after dispose` crashes.

**Recommended:** Extract a `CropAnalysisNotifier extends ChangeNotifier` with Provider or Riverpod.

### ❌ V4 polling timer fires every second, V5 every 2 seconds
```dart
// crop_analyzer_page.dart
timer = Timer.periodic(const Duration(seconds: 1), (t) async {
    final int motorState = await blynk.getVirtualPin(4);
    ...
});
```
This fires an HTTP request to Blynk every second indefinitely. Blynk free tier rate limits at 1 request/second — this will hit the limit. Use 5–10 seconds or switch to WebSocket.

### ⚠️ On-device damage formula differs from server
On-device (TFLite):
```dart
final double damage = result.isUncertain
    ? 0.0
    : ((1.0 - result.confidence) * 80.0).clamp(5.0, 80.0);
```
This is still the confidence-inversion formula, just scaled to 80. The server uses entropy-based damage. The two modes produce different damage values for the same image, which means different spray decisions.

**Fix:** Implement the entropy formula in Dart for on-device predictions, or accept the inconsistency and document it.

### ⚠️ TFLite model doesn't apply CLAHE or TTA
`TfliteService` does basic resize + normalize. The server applies bilateral filter, CLAHE, and 5-variant TTA. On-device predictions are less stable. This is an inherent tradeoff of on-device inference — document it.

---

## 4. AI / ML Server — Current Issues

### What's working well
- All critical security issues fixed (UUID files, type validation, cleanup)
- `debug=False` by default
- Entropy-based damage formula
- TTA prediction pipeline
- Confidence threshold returning "Uncertain"
- Health endpoint
- Structured logging
- Clean module separation (farm_app / inference / preprocessing)
- Training stability improved in `train_model.py`
- Evaluation normalization fixed

### ❌ `damage_estimator.py` still not wired to API
The grid-based SSIM damage estimation still runs only as a standalone `__main__` script and is never called from `farm_app.py` or `inference.py`. It still has hardcoded paths:
```python
reference_img = cv2.imread(r"D:\crop-scanner\ai_service\uploads\test1.jpeg")
```

**Fix — step 1:** Update paths:
```python
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
reference_img = cv2.imread(os.path.join(BASE_DIR, "uploads", "test1.jpeg"))
```

**Fix — step 2:** Wire into `inference.py → _build_result()` as an optional enhancement to the entropy damage estimate.

### ❌ `dataset_utils.py` hardcoded path
```python
DATASET_PATH = "D:/crop-scanner/ai_service/images"
```
One-line fix:
```python
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATASET_PATH = os.path.join(BASE_DIR, "images")
```

### ❌ `covert.py` dead code with hardcoded path
```python
model = tf.keras.models.load_model(r"D:\crop-scanner\ai_service\models\plant_disease_best.h5")
```
Fully superseded by `convert_tflite.py`. Either delete it or rename to `.bak`.

### ❌ No prediction timeout
```python
result = predict_with_tta(model, file_path, CLASS_NAMES, n_variants=5)
```
If the model hangs (rare on slow hardware), the request waits indefinitely.

**Fix (Windows-compatible):**
```python
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout

_executor = ThreadPoolExecutor(max_workers=2)

try:
    future = _executor.submit(predict_with_tta, model, file_path, CLASS_NAMES, 5)
    result = future.result(timeout=20)
except FuturesTimeout:
    return jsonify({"error": "Prediction timed out. Try a smaller image."}), 504
```

### ❌ Flask dev server is single-threaded
The default `app.run()` handles one request at a time. With two people testing simultaneously, one waits.

**Fix (Windows — use in demos):**
```bash
pip install waitress
waitress-serve --host=0.0.0.0 --port=5010 farm_app:app
```

**Fix (Linux/production):**
```bash
gunicorn -w 2 -b 0.0.0.0:5010 farm_app:app
```

### ❌ `class_names.json` may still have stale PlantVillage content
The file ships with 38 PlantVillage class names. If `train_model.py` hasn't been run, `inference.py → load_class_names()` will load the wrong 38 names, causing every prediction to have a wrong label.

**Fix:** Run `train_model.py` (it auto-writes the correct JSON), or manually set:
```json
["Anthracnose", "Bacterial_Leaf_Spot", "Black_rot", "Downy_Mildew", "Mosaic_Disease", "Powdery_Mildew", "Rust"]
```

### ⚠️ `new_train_model.py` still exists alongside `train_model.py`
Two training scripts create confusion about which one to use. `train_model.py` is correct and should be the only one. Recommend deleting or renaming `new_train_model.py` to `new_train_model.py.old`.

### ⚠️ Training vs inference preprocessing gap
`train_model.py` trains with plain rescale=1/255 (no CLAHE, no bilateral filter). `preprocessing.py` applies bilateral filter + CLAHE at inference. This is an intentional design choice (documented in `preprocessing.py` header), but it creates a domain gap. TTA in `inference.py` partially compensates.

If you retrain, do not add CLAHE to the training pipeline — it destabilizes transfer learning from ImageNet weights.

---

## 5. IoT Layer (ESP32 + Blynk) — Current Issues

### What works
- Dynamic spray duration scales with damage level
- V5 motor status pin — real feedback to Flutter
- Nozzle close sequence (reverse 1s before stop)
- Manual control via V0–V3
- Cooldown between sprays

### ❌ WiFi credentials hardcoded in firmware
```cpp
char ssid[] = "Karat";
char pass[] = "karthik12";
```
Committed to git. For a shared repo this is a real problem.

### ❌ Blynk auth token hardcoded in firmware (same as Flutter)
```cpp
#define BLYNK_AUTH_TOKEN "rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM"
```
Same token in three files. If compromised, anyone can control the motor.

### ❌ Blynk cloud dependency creates a bottleneck
The control path is: Flutter → Blynk Cloud → ESP32. If Blynk's servers are slow or rate-limited, the sprayer response is delayed. Blynk free tier: 1 API call/second, 1 device.

**Better alternative: Direct MQTT (Mosquitto)**
```
Spring Boot → MQTT broker → ESP32 (subscribes)
```
Benefits: No cloud dependency, offline capability, <50ms latency, no rate limits.

Setup:
```bash
# Install Mosquitto on server
# ESP32: use PubSubClient library
# Spring Boot: use Eclipse Paho MQTT client
```

### ❌ `blynk_auto_spray.py` still exists at root level
This standalone Python script polls Blynk and controls the sprayer independently of the ESP32 firmware. Both implement auto-spray logic, using different virtual pins. Running both simultaneously creates undefined behavior. **Do not run `blynk_auto_spray.py`** — the ESP32 firmware handles spraying correctly.

### ⚠️ Damage threshold is 5% (very sensitive)
The firmware triggers spray at `damage > 5%`. With the entropy-based damage formula, even mildly uncertain predictions produce values above 5%. This may cause false sprays if the model has borderline confidence. Consider raising to 15–20% after testing with real crop images.

---

## 6. Networking Analysis

### Current situation
Everything runs on a hardcoded local IP (`10.85.245.16`). The system only works when Flutter, Spring Boot, Python, and ESP32 are all on the same WiFi network, and the server machine has that specific IP.

### How to unblock for demos outside your network

**Option A — ngrok (fastest, for demos)**
```bash
ngrok http 8000    # gives https://abc123.ngrok.io
ngrok http 5010    # gives https://def456.ngrok.io
```
Update `lib/config.dart` with the ngrok URLs. No rebuild if you use environment variables. Free tier has session limits (8 hours).

**Option B — Tailscale (best for local-first)**
Install Tailscale on all machines. Each gets a stable private IP that works across networks without port forwarding. Free for personal use.

**Option C — Cloud deployment (permanent)**
See Deployment Plan section below.

---

## 7. Improvement Roadmap

### 🔴 Must fix before demo

| # | Fix | File | Impact |
|---|-----|------|--------|
| 1 | Update `class_names.json` to 7 classes | `models/class_names.json` | Wrong labels on every prediction |
| 2 | Use Waitress instead of Flask dev server | `farm_app.py` | Only 1 concurrent request |
| 3 | Add error handling in CropService | `CropService.java` | Flutter gets Java stack trace |
| 4 | Verify damage threshold (currently 5%) matches your damage values | `esp32_motor_control.ino` | May false-spray |

### 🟡 Should fix soon

| # | Fix | File | Effort |
|---|-----|------|--------|
| 1 | Add prediction timeout (20s) | `farm_app.py` | Low |
| 2 | Move Blynk token to env var | Flutter + `.ino` | Low |
| 3 | Move WiFi credentials to env | `.ino` | Low |
| 4 | Fix `damage_estimator.py` paths | `damage_estimator.py` | Trivial |
| 5 | Fix `dataset_utils.py` path | `dataset_utils.py` | Trivial |
| 6 | Move Spring Boot Python URL to `application.properties` | `CropService.java` | Low |
| 7 | Add multipart size limit to Spring Boot | `application.properties` | Trivial |
| 8 | Delete `new_train_model.py` and `covert.py` | both | Trivial |
| 9 | Fix on-device damage formula to use entropy | `tflite_service.dart` + `crop_analyzer_page.dart` | Medium |
| 10 | Reduce Blynk polling interval from 1s to 5–10s | `crop_analyzer_page.dart` | Trivial |

### 🔴 Advanced enhancements

**Replace Blynk with direct MQTT**

Target architecture:
```
Flutter → Spring Boot → MQTT broker (Mosquitto) → ESP32
```
- No cloud dependency
- Works offline
- Sub-50ms latency
- No rate limits
- ESP32 uses `PubSubClient` library
- Spring Boot uses Eclipse Paho MQTT client

**Wire `damage_estimator.py` into inference pipeline**

The grid-based SSIM estimator gives real pixel-level damage — more honest than the entropy formula. Integration path:
```python
# inference.py → _build_result()
from damage_estimator import calculate_damage_percent as ssim_damage
# Call ssim_damage with the uploaded image and a reference image
```

**Make Spring Boot do real work**
```java
@Entity
public class ScanRecord {
    @Id @GeneratedValue private Long id;
    private String disease;
    private double confidence;
    private double damage;
    private LocalDateTime scannedAt;
    private String fieldLocation; // GPS from Flutter
}
```

**Add fertilizer/pesticide recommendations**

`configs/fertilizer.json` exists but is never read. After disease detection:
```json
{
  "Rust": {
    "pesticide": "Mancozeb 75% WP",
    "dosage": "2.5g per liter",
    "frequency": "Every 7 days"
  }
}
```
Spring Boot reads this and appends to the response.

**GPS-tagged scan records**

Add GPS coordinates to each scan request. Build a field map in Flutter showing disease outbreak locations. Strong product differentiator.

---

## 8. Deployment Plan

### Step 1 — Deploy Python ML Server

**Recommended: Render (free tier)**

1. Ensure `requirements.txt` is present (it is)
2. Create `Procfile`:
   ```
   web: waitress-serve --host=0.0.0.0 --port=$PORT farm_app:app
   ```
3. All hardcoded paths already fixed — no changes needed
4. Push `ai_service/` to GitHub → connect to Render → deploy
5. Set env vars on Render: `FLASK_DEBUG=false`
6. URL: `https://crop-scanner-ml.onrender.com`

**Alternative: Hugging Face Spaces** (free GPU inference)

---

### Step 2 — Deploy Spring Boot Backend

**Recommended: Railway (free $5/month credit)**

1. Update `application.properties`:
   ```properties
   server.port=${PORT:8000}
   ai.service.url=${AI_SERVICE_URL:http://localhost:5010}
   spring.servlet.multipart.max-file-size=10MB
   ```
2. Create `Dockerfile`:
   ```dockerfile
   FROM eclipse-temurin:17-jre
   COPY target/spring_backend-0.0.1-SNAPSHOT.jar app.jar
   EXPOSE 8000
   ENTRYPOINT ["java", "-jar", "/app.jar"]
   ```
3. Set env var `AI_SERVICE_URL` to your Render ML server URL
4. URL: `https://crop-scanner-api.railway.app`

---

### Step 3 — Update Flutter App

```dart
// lib/config.dart
const String BASE_URL = "https://crop-scanner-api.railway.app/";
const String ML_SERVER_URL = "https://crop-scanner-ml.onrender.com";
```

Rebuild and install. The app now works from any network.

---

### Step 4 — ESP32 (no changes needed for cloud)

The ESP32 already connects to Blynk Cloud over WiFi — works from any network. For production, replace Blynk with MQTT as described in the roadmap.

---

### Cost estimate (free tiers)

| Service | Platform | Cost |
|---|---|---|
| ML server | Render free | $0 (spins down after 15min) |
| ML server (always-on) | Render paid | $7/month |
| Spring Boot | Railway free | $0 ($5 credit/month) |
| Blynk | Free tier | $0 (1 device, rate limited) |
| **Total** | | **$0–$7/month** |

---

## Summary Table

| Component | Status | Priority |
|---|---|---|
| Hardcoded `D:\` paths (main files) | ✅ Fixed | — |
| `debug=True` | ✅ Fixed | — |
| Wrong evaluation normalization | ✅ Fixed | — |
| Wrong damage% formula | ✅ Fixed | — |
| File cleanup after upload | ✅ Fixed | — |
| Path traversal in upload | ✅ Fixed | — |
| Model load crash | ✅ Fixed | — |
| No /health endpoint | ✅ Fixed | — |
| TFLite unused in Flutter | ✅ Fixed | — |
| No motor status from ESP32 | ✅ Fixed | — |
| Training instability | ✅ Fixed | — |
| Leaf detection misses diseased leaves | ✅ Fixed | — |
| `class_names.json` stale content | ❌ Run `train_model.py` | 🔴 Before demo |
| Single-threaded Flask | ❌ Use Waitress | 🔴 Before demo |
| Spring Boot no error handling | ❌ Not fixed | 🟡 Soon |
| Blynk token in source | ❌ Not fixed | 🟡 Soon |
| WiFi creds in firmware | ❌ Not fixed | 🟡 Soon |
| `damage_estimator.py` not wired | ❌ Not fixed | 🟡 Soon |
| Hardcoded paths in unused files | ❌ Not fixed | 🟢 Low |
| No prediction timeout | ❌ Not fixed | 🟡 Soon |
| Blynk cloud bottleneck | ❌ Replace with MQTT | 🔴 For production |
| No scan history | ❌ Not implemented | 🔴 Product value |
| No authentication | ❌ Not implemented | 🟡 For production |
| On-device damage formula wrong | ❌ Still confidence-inversion | 🟡 Soon |
| `new_train_model.py` not deleted | ❌ Still exists | 🟢 Low |
| `covert.py` not deleted | ❌ Still exists | 🟢 Low |

---

*Analysis based on full review of all source files: `farm_app.py`, `inference.py`, `preprocessing.py`, `train_model.py`, `new_train_model.py`, `evalute_model.py`, `convert_tflite.py`, `damage_estimator.py`, `dataset_utils.py`, `covert.py`, `tools/train_transfer.py`, `tools/split_dataset.py`, `CropController.java`, `CropService.java`, `pom.xml`, `CropAnalyzerPage.dart`, `LiveCameraPage.dart`, `BlynkScreen.dart`, `ApiService.dart`, `BlynkService.dart`, `TfliteService.dart`, `config.dart`, `pubspec.yaml`, `esp32_motor_control.ino`, `blynk_auto_spray.py`.*
