/*
 * Crop Scanner — ESP32 sprayer controller (Blynk IoT)
 *
 * Receives the leaf damage % from the app on Blynk V4 and opens the nozzle
 * (motor forward) for a time that depends on the damage, then closes it
 * (motor reverse). Reports motor state on V5.
 *
 * Credentials live in secrets.h (not committed) — copy secrets.example.h.
 *
 * Blynk datastreams (Integer, see BLYNK_SETUP.md):
 *   V0 manual forward  (button, 0/1)
 *   V1 manual reverse  (button, 0/1)
 *   V2 stop            (button, 0/1)
 *   V4 damage %        (0–100, written by the app)
 *   V5 motor status    (0/1, written by this board)
 */

#include "secrets.h"   // BLYNK_TEMPLATE_ID, BLYNK_TEMPLATE_NAME, BLYNK_AUTH_TOKEN, WIFI_SSID, WIFI_PASS

#define BLYNK_PRINT Serial

#include <WiFi.h>
#include <BlynkSimpleEsp32.h>

/******************** L293D CONNECTIONS ********************/
#define IN1 27
#define IN2 26
#define ENA 14

/******************** SPRAY SETTINGS ********************/
// Must match the app/server "Medium" threshold (AppConfig.damageMedium / DAMAGE_MEDIUM).
#define SPRAY_MIN_DAMAGE   15

// Spray duration by damage band (ms)
#define SPRAY_MS_MEDIUM    3000   // 15–24 %
#define SPRAY_MS_MEDIUM2   5000   // 25–34 %
#define SPRAY_MS_HIGH      7000   // 35–49 %
#define SPRAY_MS_SEVERE   10000   // ≥ 50 %

#define CLOSE_NOZZLE_MS    1000   // reverse time to close the nozzle
#define COOLDOWN_MS        5000   // min gap between automatic sprays
#define MANUAL_MAX_MS     15000   // manual forward/reverse auto-stops after this

// Set to 1 to run the motor forward/reverse once at boot (bench testing only)
#define RUN_SELF_TEST_ON_BOOT 0

/******************** STATE ********************/
enum MotorState { IDLE, SPRAYING, CLOSING, MANUAL };

MotorState state = IDLE;
unsigned long stateStart = 0;
unsigned long stateDuration = 0;
unsigned long lastSprayEnd = 0;
bool hasSprayed = false;
int lastReportedStatus = -1;

/******************** MOTOR OUTPUTS ********************/
void reportStatus(int running) {
  if (running != lastReportedStatus && Blynk.connected()) {
    Blynk.virtualWrite(V5, running);
    lastReportedStatus = running;
  }
}

void motorForward() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  digitalWrite(ENA, HIGH);
  reportStatus(1);
  Serial.println("Motor FORWARD");
}

void motorReverse() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, HIGH);
  digitalWrite(ENA, HIGH);
  reportStatus(1);
  Serial.println("Motor REVERSE");
}

void motorStop() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  digitalWrite(ENA, LOW);
  reportStatus(0);
  Serial.println("Motor STOP");
}

void enterState(MotorState next, unsigned long durationMs) {
  state = next;
  stateStart = millis();
  stateDuration = durationMs;
}

unsigned long sprayDurationFor(int damage) {
  if (damage < 25) return SPRAY_MS_MEDIUM;
  if (damage < 35) return SPRAY_MS_MEDIUM2;
  if (damage < 50) return SPRAY_MS_HIGH;
  return SPRAY_MS_SEVERE;
}

/******************** MANUAL CONTROLS ********************/
BLYNK_WRITE(V0) {
  if (param.asInt()) {
    Serial.println("Manual forward");
    motorForward();
    enterState(MANUAL, MANUAL_MAX_MS);
  }
}

BLYNK_WRITE(V1) {
  if (param.asInt()) {
    Serial.println("Manual reverse");
    motorReverse();
    enterState(MANUAL, MANUAL_MAX_MS);
  }
}

BLYNK_WRITE(V2) {
  if (param.asInt()) {
    Serial.println("Manual stop");
    motorStop();
    enterState(IDLE, 0);
  }
}

/******************** AI DAMAGE INPUT ********************/
BLYNK_WRITE(V4) {
  int damage = param.asInt();
  Serial.printf("Damage received: %d%%\n", damage);

  if (damage < SPRAY_MIN_DAMAGE) {
    Serial.println("Below spray threshold — no spray");
    return;
  }
  if (state != IDLE) {
    Serial.println("Motor busy — ignoring");
    return;
  }
  if (hasSprayed && millis() - lastSprayEnd < COOLDOWN_MS) {
    Serial.println("Cooldown — ignoring");
    return;
  }

  unsigned long duration = sprayDurationFor(damage);
  Serial.printf("========== START SPRAY (%lu ms) ==========\n", duration);
  motorForward();
  enterState(SPRAYING, duration);
}

BLYNK_CONNECTED() {
  // Publish the real motor state after (re)connecting
  lastReportedStatus = -1;
  reportStatus(state == IDLE ? 0 : 1);
}

/******************** SETUP ********************/
void setup() {
  Serial.begin(115200);

  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(ENA, OUTPUT);
  motorStop();  // make sure the motor is off at power-up

  Serial.println("Connecting to WiFi + Blynk...");
  Blynk.begin(BLYNK_AUTH_TOKEN, WIFI_SSID, WIFI_PASS);
  Serial.print("Connected. IP: ");
  Serial.println(WiFi.localIP());

#if RUN_SELF_TEST_ON_BOOT
  Serial.println("Self-test: forward 2s, reverse 2s");
  motorForward();
  delay(2000);
  motorReverse();
  delay(2000);
  motorStop();
#endif
}

/******************** LOOP (non-blocking) ********************/
void loop() {
  Blynk.run();

  if (state == IDLE) return;
  if (millis() - stateStart < stateDuration) return;

  switch (state) {
    case SPRAYING:
      Serial.println("========== CLOSING NOZZLE ==========");
      motorReverse();
      enterState(CLOSING, CLOSE_NOZZLE_MS);
      break;

    case CLOSING:
      motorStop();
      lastSprayEnd = millis();
      hasSprayed = true;
      enterState(IDLE, 0);
      Serial.println("========== SPRAY COMPLETE ==========");
      break;

    case MANUAL:
      Serial.println("Manual run timed out — stopping");
      motorStop();
      enterState(IDLE, 0);
      break;

    default:
      break;
  }
}
