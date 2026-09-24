/******************** BLYNK CONFIG ********************/
#define BLYNK_TEMPLATE_ID "TMPL3q4enEBLG"
#define BLYNK_TEMPLATE_NAME "ESP32 Motor Control"
#define BLYNK_AUTH_TOKEN "rXMkKMQ5NwBO1pmXM1MD1UPvW1bIL8AM"

#define BLYNK_PRINT Serial

/******************** LIBRARIES ********************/
#include <WiFi.h>
#include <BlynkSimpleEsp32.h>

/******************** WIFI ********************/
char ssid[] = "Karat";
char pass[] = "karthik12";

/******************** L293D CONNECTIONS ********************/
#define IN1 27
#define IN2 26
#define ENA 14

/******************** SETTINGS ********************/
#define DAMAGE_THRESHOLD 5

// Reverse timing for closing nozzle properly
#define REVERSE_DURATION 1000

// Cooldown between sprays
#define COOLDOWN_TIME 5000

/******************** VARIABLES ********************/
bool spraying = false;

unsigned long sprayStartTime = 0;
unsigned long lastSprayTime = 0;
unsigned long lastPrintTime = 0;

// Dynamic spray duration
unsigned long sprayDuration = 3000;

/******************** MOTOR STATUS ********************/
#define MOTOR_STATUS_VPIN V5

/******************** MOTOR FUNCTIONS ********************/
void motorForward() {

  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);

  digitalWrite(ENA, HIGH);

  Blynk.virtualWrite(V5, 1);

  Serial.println("Motor FORWARD");
}

void motorReverse() {

  digitalWrite(IN1, LOW);
  digitalWrite(IN2, HIGH);

  digitalWrite(ENA, HIGH);

  Blynk.virtualWrite(V5, 1);

  Serial.println("Motor REVERSE");
}

void motorStop() {

  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);

  digitalWrite(ENA, LOW);

  Blynk.virtualWrite(V5, 0);

  Serial.println("Motor STOP");
}

/******************** MANUAL CONTROLS ********************/
BLYNK_WRITE(V0) {

  if (param.asInt()) {

    Serial.println("Manual Forward");

    motorForward();
  }
}

BLYNK_WRITE(V1) {

  if (param.asInt()) {

    Serial.println("Manual Reverse");

    motorReverse();
  }
}

BLYNK_WRITE(V2) {

  if (param.asInt()) {

    Serial.println("Manual Stop");

    motorStop();

    spraying = false;
  }
}

/******************** AI DAMAGE INPUT ********************/
BLYNK_WRITE(V4) {

  int damage = param.asInt();

  Serial.print("Damage received: ");
  Serial.println(damage);

  unsigned long currentTime = millis();

  /******** DYNAMIC SPRAY TIME ********/
  if (damage >= 5 && damage <= 10) {

    sprayDuration = 2000;
  }
  else if (damage <= 15) {

    sprayDuration = 4000;
  }
  else if (damage <= 20) {

    sprayDuration = 6000;
  }
  else if (damage <= 25) {

    sprayDuration = 8000;
  }
  else {

    sprayDuration = 10000;
  }

  Serial.print("Spray Duration: ");
  Serial.println(sprayDuration);

  /******** START SPRAY ********/
  if (damage > DAMAGE_THRESHOLD &&
      !spraying &&
      (currentTime - lastSprayTime > COOLDOWN_TIME)) {

    Serial.println("========== START SPRAY ==========");

    // Open nozzle
    motorForward();

    spraying = true;

    sprayStartTime = currentTime;
    lastSprayTime = currentTime;
  }
}

/******************** WIFI CONNECT ********************/
void connectWiFi() {

  Serial.print("Connecting to WiFi");

  WiFi.begin(ssid, pass);

  while (WiFi.status() != WL_CONNECTED) {

    delay(500);
    Serial.print(".");
  }

  Serial.println("\nWiFi Connected");

  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());
}

/******************** SETUP ********************/
void setup() {

  Serial.begin(115200);

  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(ENA, OUTPUT);

  // Ensure OFF initially
  motorStop();

  /******** WIFI ********/
  connectWiFi();

  /******** BLYNK ********/
  Serial.println("Connecting to Blynk...");

  Blynk.begin(BLYNK_AUTH_TOKEN, ssid, pass);

  Serial.println("Blynk Connected");

  /******** MOTOR TEST ********/
  Serial.println("========== TEST START ==========");

  motorForward();
  delay(2000);

  motorReverse();
  delay(2000);

  motorStop();

  Serial.println("========== TEST END ==========");
}

/******************** LOOP ********************/
void loop() {

  Blynk.run();

  unsigned long currentTime = millis();

  /******** CLEAN SERIAL OUTPUT ********/
  if (spraying) {

    // Print every 500ms only
    if (currentTime - lastPrintTime >= 500) {

      Serial.print("Spraying Time: ");
      Serial.println(currentTime - sprayStartTime);

      lastPrintTime = currentTime;
    }

    /******** STOP SPRAY ********/
    if (currentTime - sprayStartTime >= sprayDuration) {

      Serial.println("========== CLOSING NOZZLE ==========");

      // Close nozzle
      motorReverse();

      delay(REVERSE_DURATION);

      motorStop();

      spraying = false;

      Serial.println("========== SPRAY COMPLETE ==========");
    }
  }
}