# 🌿 Crop Scanner — AI + IoT Smart Agriculture System

> Detect crop diseases from a photo. Automatically trigger pesticide spraying based on severity. Built with Flutter, Spring Boot, Python/TensorFlow, and ESP32.

---

## 📋 Table of Contents

- [Overview](#overview)
- [What Changed Since Last Version](#what-changed-since-last-version)
- [Features](#features)
- [Tech Stack](#tech-stack)
- [System Architecture](#system-architecture)
- [Data Flow](#data-flow)
- [JSON Response Format](#json-response-format)
- [Folder Structure](#folder-structure)
- [Setup Instructions](#setup-instructions)
  - [1. Python ML Server](#1-python-ml-server)
  - [2. Spring Boot Backend](#2-spring-boot-backend)
  - [3. Flutter Mobile App](#3-flutter-mobile-app)
  - [4. ESP32 IoT Device](#4-esp32-iot-device)
- [API Reference](#api-reference)
- [IoT Integration](#iot-integration)
- [Disease Classes](#disease-classes)
- [Model Files](#model-files)
- [Known Remaining Issues](#known-remaining-issues)
- [Future Improvements](#future-improvements)
- [Contributing](#contributing)

---

## Overview

Crop Scanner is an end-to-end smart agriculture system combining computer vision and IoT automation. A farmer photographs a crop leaf, the image is analyzed by a TensorFlow model running on a Flask server, and an ESP32 microcontroller automatically activates a water pump/sprayer based on the predicted damage level — no manual intervention needed.

The system supports two inference modes: server-side (Python ML server via Spring Boot) and on-device (TFLite model bundled in the Flutter app), with automatic fallback between them.

---

## What Changed Since Last Version

This documents every significant change made during the major refactor. Read this if you're an AI model or developer picking up where the last session left off.

### Python ML Server (`ai_service/`)

- **`farm_app.py` fully rewritten** — all hardcoded `D:\` paths replaced with `os.path.dirname(os.path.abspath(__file__))`. `debug=True` removed; controlled via `FLASK_DEBUG` env var. UUID filenames for uploads. File cleanup in `finally` block. File type validation (jpg/jpeg/png/webp). 10 MB request size limit. Structured logging (`logging` module, no more `print()`). `/health` endpoint added. Imports `inference.py` and `preprocessing.py` instead of inlining everything.
- **`inference.py` — new file** — all prediction logic extracted here. `load_keras_model()` with graceful error handling and warm-up. `load_class_names()` with fallback to hardcoded list. `predict_with_tta()` for 5-variant test-time augmentation. `predict_single()` as fallback. `calculate_damage_percent()` using entropy-based formula (replaces wrong `(1-confidence)*100`). Confidence threshold: below 50% returns `"Uncertain"` instead of a wrong label. Response includes `severity`, `spray_recommended`, `frames_averaged`.
- **`preprocessing.py` — new file** — single source of truth for all image processing. `is_leaf_present()` now detects both green and yellow-brown (diseased) leaves. `preprocess_for_inference()` pipeline: letterbox resize → bilateral filter → CLAHE → normalize. `generate_tta_variants()` for 5 augmented variants. Accepts file path, bytes, or numpy array as input.
- **`train_model.py` — new file** — replaces `new_train_model.py`. Stability fixes: LR lowered 1e-3 → 3e-4, fine-tune only last 15 layers (not 40), class weight capped at 2.0, gradient clipping (`clipnorm=1.0`), label smoothing 0.1 → 0.05. Fine-tuning gated: only runs if Phase 1 reaches 50% val accuracy. Saves `crop_model_best.h5` and `crop_model.h5`. Auto-writes correct `class_names.json`.
- **`evalute_model.py` fixed** — normalization corrected from `/127.5-1.0` to `/255.0` to match training. Per-class accuracy breakdown. Confusion matrix and confidence distribution saved as PNG (no display required). Actionable feedback printed per class.
- **`requirements.txt` added** — pinned versions for all dependencies: tensorflow, numpy, opencv, flask, waitress, scipy, scikit-learn, matplotlib, seaborn, python-dotenv.
- **`convert_tflite.py`** — upgraded to support `--mode float32`, `--mode float16`, `--mode int8` via CLI. Int8 mode includes representative dataset calibration.
- **Multiple model files now present** in `ai_service/models/`: `crop_model_best.h5`, `crop_model.h5`, `new_model.h5`, `crop_model_float16.tflite`, `new_model.tflite`.
- **`tools/` folder added** — contains `train_transfer.py` (alternative training script using dataset_split), `split_dataset.py` (70/20/10 split utility), `train_transfer_two_step.py`, `prepare_binary_dataset.py`.
- **`AI_SERVICES_ANALYSIS.md` added** — detailed architecture and status report for the Python layer.

### Flutter App (`flutter_app/`)

- **TFLite on-device inference now wired and working** — `TfliteService` is no longer dead code. App loads `crop_model_float16.tflite` from assets. Users can toggle between server and on-device inference via the top-right button in the analyzer page. On-device inference falls back to server on failure; server inference falls back to on-device.
- **`tflite_flutter: ^0.12.1`** — upgraded from `^0.10.4` to fix `UnmodifiableUint8ListView` crash on Dart 3.x. `image: ^4.0.4` added for pixel-level tensor construction.
- **`usb_serial` dependency removed** from `pubspec.yaml` (was unused).
- **`TfliteResult` model class** — clean result type with `disease`, `confidence`, `isUncertain`, `allProbs`, `inferenceMs`.
- **Inference source badge** — UI shows "On-device TFLite", "Server", or "Server (fallback)" + inference time in ms.
- **Motor status via V5** — `BlynkService.getMotorStatus()` added, reads V5 (ESP32 writes V5 on motor state change). `CropAnalyzerPage` and `LiveCameraPage` both poll V5 every 2 seconds.
- **Severity thresholds updated** — `CropAnalyzerPage.getSeverity()` now uses `< 15` → Low, `< 35` → Medium, `≥ 35` → High (was 30/60 threshold from old formula).
- **Deduplication for Blynk sends** — damage value is only sent to V4 if it changed since last send (`lastSentDamagePercent` guard).
- **`blynk_screen.dart` added** — standalone Blynk control screen (currently not linked from main nav but available).
- **`loading_overlay.dart` added** — reusable loading widget.
- **`image_picker_buttons.dart` added** — extracted gallery/camera button row as reusable widget.
- **`image_preview.dart` added** — extracted image preview container as reusable widget.
- **IP updated** in `config.dart` — `10.85.245.16` (was `10.214.65.16`). Update to your current machine IP before running.
- **`google_fonts: ^6.1.0`** added — used in `HomeScreen` for Poppins/Lato fonts.

### ESP32 Firmware (`ardunio/`)

- **Dynamic spray duration** based on damage level (was fixed 2s): 5–10% → 2s, ≤15% → 4s, ≤20% → 6s, ≤25% → 8s, >25% → 10s.
- **Damage threshold lowered** to 5% (was 30%) — matches the new entropy-based damage values which are lower on average than the old confidence-inversion formula.
- **V5 motor status pin** — ESP32 now writes `1` to V5 when motor is running, `0` when stopped. Flutter reads this to show real motor status.
- **Nozzle close sequence** — after spray duration, motor runs reverse for `REVERSE_DURATION` (1000ms) to close nozzle before stopping.
- **WiFi credentials updated** — `ssid[] = "Karat"`, `pass[] = "karthik12"`.
- **Cooldown** still 5 seconds between sprays.

### Spring Boot Backend (`spring_backend/`)

- **`spring-boot-starter-parent` version bumped** to `3.5.5` (was `3.x`).
- Architecture and code unchanged — still a proxy forwarding to Python. See Known Remaining Issues.

---

## Features

- 📸 **Image capture** from camera or gallery
- 📱 **On-device TFLite inference** — works offline, ~instant response
- ☁️ **Server inference** — full TTA pipeline via Python ML server
- 🔄 **Automatic fallback** — on-device → server and server → on-device
- 🤖 **AI disease detection** across 7 crop disease classes
- 📊 **Confidence & damage percentage** displayed in real time
- 🔍 **Severity label** — Low / Medium / High mapped from damage %
- ⚠️ **Uncertain response** — low-confidence predictions flagged instead of guessing
- 🎥 **Live camera mode** — continuous webcam capture and analysis every 3 seconds
- 🌿 **Leaf presence validation** — detects green and diseased (yellow-brown) leaves
- ⚡ **Automated spraying** — ESP32 motor duration scales with damage level
- 🕹️ **Manual motor control** — forward, reverse, stop, speed via Blynk app
- 📡 **Real motor status** — ESP32 writes V5 pin; Flutter reads it every 2 seconds
- 🔒 **Security improvements** — UUID upload names, file type validation, no debug mode

---

## Tech Stack

| Layer | Technology |
|---|---|
| Mobile App | Flutter (Dart) 3.7+, `image_picker`, `http`, `tflite_flutter ^0.12.1`, `image ^4.0.4`, `google_fonts` |
| Backend | Spring Boot 3.5.5 (Java 17), Spring Web, WebFlux, Actuator |
| ML Server | Python 3, Flask 3.0, TensorFlow 2.15, OpenCV 4.9, SciPy, Waitress |
| ML Model | MobileNetV2 (transfer learning, 224×224), `.h5` + `.tflite` (float16) |
| Preprocessing | Letterbox resize, bilateral filter, CLAHE, 5-variant TTA |
| IoT Hardware | ESP32, L298N Motor Driver, Water Pump/Relay |
| IoT Platform | Blynk IoT Cloud (REST API + virtual pins V0–V5) |
| Database | MySQL (configured in Spring Boot, not actively used) |

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FLUTTER MOBILE APP                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │ Image Picker │  │ Live Camera  │  │  Results Display     │  │
│  │ (cam/gallery)│  │ (3s interval)│  │  disease/damage/sev  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────────┘  │
│         └─────────────────┘                                     │
│  ┌──────────────────────┐  ┌───────────────────────────────┐    │
│  │  TfliteService       │  │  Toggle: On-device / Server   │    │
│  │  (on-device fallback)│  │  badge shown in UI            │    │
│  └──────────────────────┘  └───────────────────────────────┘    │
│                    │ POST /api/crop/analyze                      │
└────────────────────┼────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│              SPRING BOOT BACKEND  (port 8000)                   │
│  CropController → CropService                                   │
│  Receives multipart image, forwards to Python ML server         │
└─────────────────────────────┬───────────────────────────────────┘
                              │ POST /api/crop/analyze
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              PYTHON ML SERVER  (port 5010)                      │
│  farm_app.py        ← HTTP routing only                         │
│       ↓                                                         │
│  preprocessing.py   ← leaf check, letterbox, CLAHE, TTA        │
│       ↓                                                         │
│  inference.py       ← model.predict, TTA avg, damage calc      │
│       ↓                                                         │
│  models/            ← crop_model_best.h5, class_names.json     │
└─────────────────────────────────────────────────────────────────┘
                              │ JSON response
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              FLUTTER APP  (receives result)                     │
│  Sends damage% → Blynk Virtual Pin V4                          │
│  Reads motor status ← Blynk Virtual Pin V5                     │
└─────────────────────────────┬───────────────────────────────────┘
                              │ Blynk REST API
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              BLYNK CLOUD                                        │
│  V4 = damage percentage (written by Flutter)                   │
│  V5 = motor status (written by ESP32)                          │
└─────────────────────────────┬───────────────────────────────────┘
                              │ BLYNK_WRITE(V4)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              ESP32 IoT DEVICE                                   │
│  damage >= 5%    → Activate motor (duration scales with damage) │
│  damage < 5%     → Motor stays off                              │
│  Nozzle close    → Reverse for 1s before stop                  │
│  Cooldown: 5 seconds between sprays                            │
│  GPIO 27 (IN1), GPIO 26 (IN2), GPIO 14 (ENA/PWM)              │
│  Writes V5 → 1 (running) or 0 (stopped) after each action     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Step-by-Step Request Lifecycle

```
1.  User opens Flutter app
2.  Captures or selects a crop leaf image
3.  Flutter checks: is TFLite loaded? Use on-device or server?
    a. ON-DEVICE PATH:
       - TfliteService.predictFromFile() runs locally
       - Result shown with "On-device TFLite" badge + inference ms
       - If TFLite fails → falls back to server
    b. SERVER PATH:
       - Flutter sends POST /api/crop/analyze to Spring Boot (port 8000)
       - Spring Boot forwards to Python Flask server (port 5010)
       - Flask server:
           i.   Validates file type (jpg/jpeg/png/webp only)
           ii.  Saves with UUID filename (no original filename used)
           iii. Checks leaf presence (green + yellow-brown HSV mask)
           iv.  Runs TTA prediction (5 augmented variants averaged):
                  - Original, H-flip, +10° rotate, -10° rotate, +15% brightness
           v.   Checks confidence threshold (< 50% → returns "Uncertain")
           vi.  Calculates entropy-based damage % (not confidence inversion)
           vii. Cleans up uploaded file (finally block)
           viii.Returns enriched JSON
       - Spring Boot returns JSON to Flutter
4.  Flutter displays: disease, severity, damage %, confidence bar, source badge
5.  Flutter sends damage% to Blynk Virtual Pin V4 (only if value changed)
6.  Flutter polls Blynk Virtual Pin V5 every 2 seconds → shows motor status
7.  ESP32 reads V4 via BLYNK_WRITE(V4):
       - damage >= 5%: motor activates, duration scales with severity
       - After spray: reverse for 1s (close nozzle) → stop
       - Writes V5=1 on start, V5=0 on stop
       - 5 second cooldown between sprays
```

---

## JSON Response Format

### Successful Prediction

```json
{
  "crop": "Rust",
  "status": "Diseased",
  "disease": "Rust",
  "confidence_percent": 87.34,
  "damage_percent": 38.21,
  "severity": "Medium",
  "spray_recommended": true,
  "frames_averaged": 5,
  "all_class_probs": {
    "Anthracnose": 1.02,
    "Bacterial_Leaf_Spot": 0.54,
    "Black_rot": 0.88,
    "Downy_Mildew": 2.11,
    "Mosaic_Disease": 0.73,
    "Powdery_Mildew": 7.38,
    "Rust": 87.34
  }
}
```

### Uncertain Prediction (confidence < 50%)

```json
{
  "crop": "Unknown",
  "status": "Uncertain",
  "disease": "Uncertain",
  "confidence_percent": 34.10,
  "damage_percent": 0.0,
  "severity": "Unknown",
  "message": "Model confidence too low (34.1%). Please retake the photo with better lighting and a clear leaf.",
  "frames_averaged": 5
}
```

### Damage Percent Interpretation

The `damage_percent` field uses an entropy-based formula — NOT confidence inversion. Higher entropy (more spread-out probabilities = more uncertain) produces higher damage.

| Damage % | Severity | Spray Action (ESP32) |
|---|---|---|
| < 5% | Low | No spray |
| 5–14% | Low | 2s spray |
| 15–19% | Low/Medium | 4s spray |
| 20–24% | Medium | 6s spray |
| 25–34% | Medium | 8s spray |
| ≥ 35% | High | 10s spray |

Note: Flutter's `getSeverity()` uses `< 15` → Low, `< 35` → Medium, `≥ 35` → High.

---

## Folder Structure

```
crop-scanner/
│
├── ai_service/                         # Python ML server
│   ├── farm_app.py                     # Flask API — main entry point (refactored)
│   ├── inference.py                    # NEW — prediction engine, TTA, damage calc
│   ├── preprocessing.py                # NEW — shared preprocessing pipeline
│   ├── train_model.py                  # NEW — stable training pipeline (use this)
│   ├── evalute_model.py                # Evaluation + confusion matrix (fixed)
│   ├── convert_tflite.py               # .h5 → .tflite, supports float32/float16/int8
│   ├── requirements.txt                # NEW — pinned dependencies
│   ├── new_train_model.py              # OLD training script (superseded by train_model.py)
│   ├── damage_estimator.py             # Grid-based SSIM damage (not wired to API)
│   ├── dataset_utils.py                # Dataset helpers (has hardcoded path, unused by API)
│   ├── covert.py                       # OLD one-liner TFLite conversion (superseded)
│   ├── AI_SERVICES_ANALYSIS.md         # NEW — detailed architecture status document
│   ├── configs/
│   │   └── fertilizer.json             # Fertilizer recommendation config (unused)
│   ├── models/
│   │   ├── crop_model_best.h5          # Best checkpoint from train_model.py (USE THIS)
│   │   ├── crop_model.h5               # Final epoch from train_model.py
│   │   ├── crop_model_float16.tflite   # Float16 TFLite — used by Flutter app
│   │   ├── new_model.h5                # From new_train_model.py
│   │   ├── new_model.tflite            # TFLite from new_model.h5
│   │   ├── plant_disease_best.h5       # From tools/train_transfer.py
│   │   ├── plant_disease_cnn.h5        # From tools/train_transfer.py
│   │   ├── class_names.json            # 7 class names (written by train_model.py)
│   │   └── training_curve.png          # Training accuracy plot
│   ├── images/                         # Training dataset (7 disease folders)
│   │   ├── Anthracnose/
│   │   ├── Bacterial_Leaf_Spot/
│   │   ├── Black_rot/
│   │   ├── Downy_Mildew/
│   │   ├── Mosaic_Disease/
│   │   ├── Powdery_Mildew/
│   │   └── Rust/
│   ├── tools/                          # NEW — training utilities
│   │   ├── split_dataset.py            # Split images/ into train/val/test (70/20/10)
│   │   ├── train_transfer.py           # Alternative training using dataset_split
│   │   ├── train_transfer_two_step.py  # Two-phase variant
│   │   └── prepare_binary_dataset.py   # Binary dataset prep utility
│   └── uploads/                        # Temp upload directory (auto-created, auto-cleaned)
│
├── spring_backend/
│   └── spring_backend_fresh/
│       └── spring_backend/
│           ├── pom.xml                 # Spring Boot 3.5.5, Java 17
│           └── src/main/java/com/example/spring_backend/
│               ├── controller/
│               │   └── CropController.java     # REST endpoints
│               ├── service/
│               │   ├── CropService.java        # Forwards image to Python
│               │   └── AIServiceClient.java    # WebClient (unused)
│               └── model/
│                   └── CropAnalysisResult.java # DTO (unused)
│
├── flutter_app/
│   ├── pubspec.yaml
│   └── lib/
│       ├── main.dart                   # Loads TFLite model at startup
│       ├── config.dart                 # Base URLs — UPDATE IP BEFORE RUNNING
│       ├── screens/
│       │   ├── home_screen.dart        # Welcome screen with Start button
│       │   ├── crop_analyzer_page.dart # Main analysis UI (image/on-device/server)
│       │   └── blynk_screen.dart       # NEW — standalone Blynk control screen
│       ├── services/
│       │   ├── api_service.dart        # HTTP upload (File or bytes)
│       │   ├── blynk_service.dart      # Blynk REST API (set/get V-pins + getMotorStatus)
│       │   └── tflite_service.dart     # On-device TFLite inference (NOW WIRED)
│       ├── widgets/
│       │   ├── info_card.dart          # Metric display card
│       │   ├── live_camera_page.dart   # Continuous capture widget
│       │   ├── loading_overlay.dart    # NEW — reusable loading spinner
│       │   ├── image_picker_buttons.dart # NEW — gallery/camera button row
│       │   └── image_preview.dart      # NEW — image preview container
│       ├── theme/
│       │   └── app_theme.dart
│       └── assets/
│           ├── images/svce_logo.png
│           └── models/crop_model_float16.tflite  # Bundled TFLite model
│
├── ardunio/
│   └── esp32_motor_control/
│       └── esp32_motor_control.ino     # ESP32 firmware (updated)
│
├── blynk_auto_spray.py                 # Standalone Blynk polling (redundant, do not run)
├── webcam.py                           # Standalone webcam server (port 5011)
├── connection_setup.md                 # Hardware wiring guide
└── README.md
```

---

## Setup Instructions

> **Prerequisites:** All services must run on the same local WiFi network. Update the IP in `flutter_app/lib/config.dart` to your machine's current local IP before running the app.

### 1. Python ML Server

**Requirements:** Python 3.9+

```bash
cd ai_service

# Install all dependencies (pinned versions)
pip install -r requirements.txt

# Ensure the trained model exists at one of these paths:
#   ai_service/models/crop_model_best.h5   ← preferred
#   ai_service/models/new_model.h5          ← fallback
# If neither exists, run training first:
python train_model.py

# Start in development mode (single-threaded, auto-reload)
set FLASK_DEBUG=true
python farm_app.py

# Start in demo/production mode (multi-request, recommended for demos)
waitress-serve --host=0.0.0.0 --port=5010 farm_app:app
```

**Verify it's running:**
```bash
curl http://localhost:5010/health
# Returns: {"status": "ok", "model_loaded": true, "classes": [...], "num_classes": 7}
```

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `FLASK_DEBUG` | `false` | Set `true` for dev auto-reload |
| `FLASK_PORT` | `5010` | Port to listen on |

---

### 2. Spring Boot Backend

**Requirements:** Java 17, Maven

```bash
cd spring_backend/spring_backend_fresh/spring_backend

# Build
mvn clean install

# Run
mvn spring-boot:run
# Server starts at http://localhost:8000
```

**Verify it's running:**
```bash
curl http://localhost:8000/api/crop/test
# Returns: Crop API is working!
```

> The Python ML server must be running before Spring Boot can process image requests.
> Spring Boot forwards images to `http://127.0.0.1:5010/api/crop/analyze`.

---

### 3. Flutter Mobile App

**Requirements:** Flutter SDK 3.7+, Android device or emulator

```bash
cd flutter_app

# 1. Update the IP address in lib/config.dart
#    Replace 10.85.245.16 with your machine's current local IP

# 2. Install dependencies
flutter pub get

# 3. Run on connected device
flutter run
```

**`lib/config.dart` — update before every network change:**
```dart
const String BASE_URL = "http://<YOUR_LOCAL_IP>:8000/";
const String WEBCAM_SERVER_URL = "http://<YOUR_LOCAL_IP>:5011";
const String ML_SERVER_URL = "http://<YOUR_LOCAL_IP>:5010";
```

**Inference mode toggle:** Tap the phone/cloud icon in the top-right of the analyzer screen to switch between on-device TFLite and server inference.

**On-device TFLite:** The model `assets/models/crop_model_float16.tflite` is bundled in the app. If the model file changes, rebuild the app with `flutter run`. The TFLite model uses a 60% confidence threshold (vs 50% on server) and does not apply CLAHE or TTA.

---

### 4. ESP32 IoT Device

**Requirements:** Arduino IDE, ESP32 board support, Blynk library

1. Open `ardunio/esp32_motor_control/esp32_motor_control.ino` in Arduino IDE
2. Install the **Blynk** library via Library Manager
3. Update WiFi credentials if needed:
   ```cpp
   char ssid[] = "YOUR_WIFI_SSID";
   char pass[] = "YOUR_WIFI_PASSWORD";
   ```
4. Flash to ESP32

**Hardware connections:**

| ESP32 Pin | L298N Pin | Purpose |
|---|---|---|
| GPIO 27 (IN1) | IN1 | Motor direction 1 |
| GPIO 26 (IN2) | IN2 | Motor direction 2 |
| GPIO 14 (ENA) | ENA | Enable / PWM speed |
| GND | GND | Common ground (MUST be connected) |

**Blynk Virtual Pin Map:**

| Pin | Direction | Function |
|-----|-----------|----------|
| V0 | Flutter → ESP32 | Manual Forward |
| V1 | Flutter → ESP32 | Manual Reverse |
| V2 | Flutter → ESP32 | Manual Stop |
| V3 | Flutter → ESP32 | Speed Control (0–255) |
| V4 | Flutter → ESP32 | AI Damage % (auto-spray trigger) |
| V5 | ESP32 → Flutter | Motor Status (1=running, 0=stopped) |

---

## API Reference

### Python ML Server (port 5010)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Service info + available endpoints |
| `GET` | `/health` | Liveness check — call before sending images |
| `POST` | `/api/crop/analyze` | Analyze crop image for disease |
| `GET` | `/capture` | Capture frame from webcam (port must have camera) |

**POST `/api/crop/analyze`**

- **Content-Type:** `multipart/form-data`
- **Body field:** `file` — image file (JPG, JPEG, PNG, or WebP, max 10MB)
- **Success (200):** see JSON Response Format section above
- **Errors:**
  - `400` — No file / empty filename / unsupported type / no leaf detected / corrupt image
  - `500` — Prediction failed

---

### Spring Boot Backend (port 8000)

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/crop/test` | Health check string |
| `POST` | `/api/crop/analyze` | Proxy — forwards image to Python server, returns raw response |

---

## IoT Integration

The ESP32 connects to Blynk Cloud over WiFi. After each scan, Flutter writes the damage percentage to V4. The ESP32 firmware listens via `BLYNK_WRITE(V4)`.

**Auto-Spray Logic (current firmware):**
```
damage >= 5%:
  5–10%  → spray 2 seconds
  ≤15%   → spray 4 seconds
  ≤20%   → spray 6 seconds
  ≤25%   → spray 8 seconds
  >25%   → spray 10 seconds
  After spray: reverse motor 1s (close nozzle) → stop
  5s cooldown between activations

damage < 5% → motor stays off
```

**Motor Status Feedback:**
ESP32 writes `1` to V5 when motor starts, `0` when it stops. Flutter polls V5 every 2 seconds and displays "Running" / "Stopped" in the motor status card.

**Manual Control** is available through the Blynk mobile app using V0 (forward), V1 (reverse), V2 (stop), and V3 (speed slider 0–255).

---

## Disease Classes

The model is trained to detect 7 crop diseases. All 7 classes are diseases — there is no "Healthy" class. A prediction always returns a disease name; if confidence is below 50%, the system returns "Uncertain" instead.

| # | Disease | Description |
|---|---------|-------------|
| 1 | Anthracnose | Fungal disease causing dark, sunken lesions on leaves and stems |
| 2 | Bacterial Leaf Spot | Bacterial infection producing water-soaked spots that turn brown |
| 3 | Black Rot | Fungal disease causing V-shaped yellow lesions and black necrotic areas |
| 4 | Downy Mildew | Oomycete infection causing yellow patches on upper leaf surface |
| 5 | Mosaic Disease | Viral infection producing mosaic-like light/dark green discoloration |
| 6 | Powdery Mildew | Fungal disease with white powdery coating on leaf surface |
| 7 | Rust | Fungal disease with rust-colored pustules on leaf underside |

---

## Model Files

| File | Description | Used by |
|---|---|---|
| `models/crop_model_best.h5` | Best val_accuracy checkpoint from `train_model.py` | `farm_app.py` (primary) |
| `models/crop_model.h5` | Final epoch from `train_model.py` | Backup |
| `models/crop_model_float16.tflite` | Float16 TFLite from `crop_model_best.h5` | Flutter app |
| `models/new_model.h5` | From old `new_train_model.py` | `farm_app.py` (fallback if best not found) |
| `models/new_model.tflite` | TFLite from `new_model.h5` | Not currently used |
| `models/plant_disease_best.h5` | From `tools/train_transfer.py` | Not used by API |
| `models/class_names.json` | 7 class labels — auto-written by `train_model.py` | `inference.py` |

> **Important:** If `class_names.json` contains 38 PlantVillage names (the old content), the predictions will have wrong labels. Run `train_model.py` to regenerate it, or manually set it to: `["Anthracnose", "Bacterial_Leaf_Spot", "Black_rot", "Downy_Mildew", "Mosaic_Disease", "Powdery_Mildew", "Rust"]`

---

## Known Remaining Issues

These issues exist in the current codebase. See [TECHNICAL_FEEDBACK.md](TECHNICAL_FEEDBACK.md) for full detail and fixes.

### Must fix before demo

| Issue | File | Impact |
|---|---|---|
| `class_names.json` may have stale 38-class PlantVillage content | `models/class_names.json` | Wrong disease labels on every prediction |
| Flask runs single-threaded in dev mode | `farm_app.py` | Requests queue — only one at a time |
| Blynk auth token hardcoded in source | `crop_analyzer_page.dart`, `.ino` | Token is in git history |
| WiFi credentials hardcoded in firmware | `esp32_motor_control.ino` | Password is in git history |

### Should fix

| Issue | File | Impact |
|---|---|---|
| `damage_estimator.py` not wired to API | `damage_estimator.py` | Entropy formula used instead of real pixel damage |
| `damage_estimator.py` has hardcoded `D:\` path | `damage_estimator.py` | Crashes if run standalone on any other machine |
| `dataset_utils.py` has hardcoded `D:\` path | `dataset_utils.py` | Crashes if run on any other machine |
| No prediction timeout | `farm_app.py` | Client waits indefinitely if model hangs |
| Spring Boot has no error handling for Python being down | `CropService.java` | Java stack trace returned to Flutter |
| Spring Boot Python URL hardcoded | `CropService.java` | Must recompile to point to different server |
| Three IPs hardcoded in Flutter config | `config.dart` | Must update and rebuild on every network change |
| No state management in Flutter | `crop_analyzer_page.dart` | Business logic mixed with UI |
| Blynk polling at 1s interval for V4 | `crop_analyzer_page.dart` | HTTP request every second, risks rate limit |
| `new_train_model.py` still exists alongside `train_model.py` | `new_train_model.py` | Confusing — which one to run? |
| `covert.py` still exists with hardcoded path | `covert.py` | Dead code, hardcoded path |
| MySQL dependency in `pom.xml` but nothing uses it | `pom.xml` | Startup error if MySQL isn't running |

---

## Future Improvements

See [TECHNICAL_FEEDBACK.md](TECHNICAL_FEEDBACK.md) for the full roadmap with code examples.

**High Priority:**
- Switch Flask to Waitress: `waitress-serve --host=0.0.0.0 --port=5010 farm_app:app`
- Add `ThreadPoolExecutor` prediction timeout (20s) in `farm_app.py`
- Wire `damage_estimator.py` into `inference.py` for real pixel-level damage
- Move Blynk token and WiFi password to environment variables / `.env`
- Add error handling in `CropService.java` for when Python is down
- Move Python URL to `application.properties`

**Medium Priority:**
- Replace Blynk with direct MQTT (Mosquitto) — removes cloud dependency, enables offline use, <50ms latency
- Deploy Python ML server to cloud (Render/HuggingFace free tier)
- Deploy Spring Boot to cloud (Railway free tier)
- Add scan history using MySQL (entity already configured, just unused)
- Add JWT authentication to Spring Boot endpoints
- Wire `configs/fertilizer.json` into API response for pesticide recommendations

**Advanced:**
- Add GPS coordinates to scan records → field disease map
- Implement proper state management in Flutter (Provider or Riverpod)
- Remove `new_train_model.py` and `covert.py` (superseded)

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Commit your changes: `git commit -m "Add your feature"`
4. Push: `git push origin feature/your-feature`
5. Open a Pull Request

---

## License

This project is for educational and research purposes.

---

*Built as part of an AI + IoT Smart Agriculture project.*  
*Full technical analysis and improvement roadmap: [TECHNICAL_FEEDBACK.md](TECHNICAL_FEEDBACK.md)*  
*Python layer architecture and status: [ai_service/AI_SERVICES_ANALYSIS.md](ai_service/AI_SERVICES_ANALYSIS.md)*
