# ESP32 + L293D + 12V DC Motor Connection Guide

## Components Used

* ESP32 Dev Board
* L293D Motor Driver Module
* 12V DC Gear Motor
* 12V Battery Pack
* Jumper Wires
* DC Barrel Jack Connector
* Blynk IoT Platform

---

# System Overview

```text
Flutter AI App
      ↓
Blynk Cloud
      ↓
ESP32
      ↓
L293D Motor Driver
      ↓
12V DC Motor
```

The ESP32 controls the motor through the L293D driver.

* Forward → Opens nozzle
* Reverse → Closes nozzle
* Stop → Stops motor

---

# IMPORTANT CONCEPT

## NEVER connect the motor directly to ESP32.

The ESP32 cannot provide enough current for the motor.

Correct flow:

```text
Battery → L293D → Motor
ESP32 → Control Signals Only
```

---

# ESP32 to L293D Connections

| ESP32 Pin    | L293D Pin | Purpose           |
| ------------ | --------- | ----------------- |
| D27 (GPIO27) | IN1       | Motor Direction 1 |
| D26 (GPIO26) | IN2       | Motor Direction 2 |
| D14 (GPIO14) | ENA       | Enable Motor      |
| GND          | GND       | Common Ground     |

---

# Motor Connections

| Motor Wire   | L293D |
| ------------ | ----- |
| Motor Wire 1 | M1    |
| Motor Wire 2 | M2    |

If motor direction is opposite:

* swap the motor wires.


---

# Battery Connections

| Battery Wire | L293D     |
| ------------ | --------- |
| +12V (Red)   | VCC Motor |
| GND (Black)  | GND       |

---

# VERY IMPORTANT GROUND CONNECTION

ESP32 GND MUST connect to L293D GND.

Without common ground:

* motor behaves unstable
* random resets happen
* commands fail

Correct:

```text
ESP32 GND ─── L293D GND ─── Battery GND
```

---

# Motor Driver Logic

## Forward Rotation

```cpp
IN1 = HIGH
IN2 = LOW
ENA = HIGH
```

Motor rotates forward.

---

## Reverse Rotation

```cpp
IN1 = LOW
IN2 = HIGH
ENA = HIGH
```

Motor rotates backward.

---

## Stop Motor

```cpp
IN1 = LOW
IN2 = LOW
ENA = LOW
```

Motor stops.

---

# Blynk Virtual Pins

| Virtual Pin | Function        |
| ----------- | --------------- |
| V0          | Manual Forward  |
| V1          | Manual Reverse  |
| V2          | Stop Motor      |
| V4          | AI Damage Input |
| V5          | Motor Status    |

---

# AI Spray Logic

When Flutter sends:

```text
Damage > Threshold
```

ESP32:

1. Opens nozzle (forward)
2. Runs spray for fixed duration
3. Closes nozzle (reverse)
4. Stops motor

---

# Common Problems & Fixes

---

## 1. Motor Not Running

### Causes

* loose wire
* weak battery
* ENA not connected
* no common ground

### Fix

* tighten all connections
* connect grounds together
* check battery voltage

---

## 2. ESP32 Restarting

### Cause

Motor draws high current.

### Fix

Use separate battery for motor.

---

## 3. Motor Runs Continuously

### Cause

ENA always HIGH or incorrect code.

### Fix

Use:

```cpp
digitalWrite(ENA, LOW);
```

inside motorStop().

---

## 4. Blynk Not Connecting

### Causes

* wrong auth token
* weak WiFi
* firewall/network issue

### Fix

* verify token
* reconnect WiFi
* restart ESP32

---

# Stable Demo Setup Tips

* Tighten screw terminals firmly
* Use electrical tape on loose wires
* Keep setup flat on table
* Avoid moving wires while running
* Use thicker power wires if possible

---

# Final Working Flow

```text
Leaf Image
    ↓
Flutter AI Detection
    ↓
Disease Percentage
    ↓
Blynk Cloud
    ↓
ESP32
    ↓
L293D Driver
    ↓
12V Motor
    ↓
Automatic Spray System
```

---

