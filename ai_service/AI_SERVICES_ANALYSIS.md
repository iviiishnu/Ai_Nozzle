# Crop Scanner AI Service Architecture

## Project Overview

Crop Scanner is an AI-powered crop disease detection and automated spraying system.

The objective of the system is to help farmers identify crop diseases from leaf images and automatically trigger preventive actions through an IoT-enabled spraying mechanism.

The complete system consists of four major layers:

1. Flutter Mobile Application
2. Spring Boot Backend
3. AI Prediction Service (Python + Deep Learning)
4. IoT Layer (ESP32 + Blynk)

The AI service is responsible for analyzing leaf images, detecting diseases, estimating severity, and returning actionable recommendations.

---

# High Level Architecture

```text
Farmer
   ↓
Flutter Mobile App
   ↓
Spring Boot Backend
   ↓
Python AI Service
   ↓
Disease Prediction
   ↓
Severity Analysis
   ↓
IoT Spray Recommendation
   ↓
ESP32 Sprayer Control
```

---

# System Workflow

The complete prediction workflow follows the steps below.

## Step 1: Image Upload

The farmer captures a crop leaf image using the mobile application.

The image is sent to the Spring Boot backend through a secure API request.

```text
Farmer
   ↓
Flutter App
   ↓
Spring Boot Backend
```

---

## Step 2: AI Service Invocation

The backend forwards the image to the Python AI server.

Before processing any image, the backend verifies that the AI service is running through a health-check endpoint.

```text
GET /health
```

If the service is available, the image is forwarded for analysis.

---

## Step 3: Leaf Detection

The first validation step checks whether the uploaded image actually contains a crop leaf.

This is achieved using HSV color-space analysis.

The system detects:

* Healthy green leaf regions
* Yellow leaf regions
* Brown diseased leaf regions

Images without sufficient leaf content are rejected.

Examples:

* Leaf image → Accepted
* Wall image → Rejected
* Table image → Rejected
* Bottle image → Rejected

Purpose:

* Reduce false predictions
* Prevent unnecessary AI processing
* Improve prediction reliability

---

## Step 4: Image Preprocessing

Before sending the image to the neural network, several preprocessing operations are applied.

### 4.1 Aspect Ratio Preserving Resize

Images are resized to:

```text
224 × 224
```

while preserving the original aspect ratio.

This avoids distortion of disease patterns.

---

### 4.2 Noise Reduction

A Bilateral Filter is applied.

Benefits:

* Removes camera noise
* Preserves leaf edges
* Preserves disease spot boundaries

---

### 4.3 Contrast Enhancement

CLAHE (Contrast Limited Adaptive Histogram Equalization) is applied.

Benefits:

* Improves visibility in low-light conditions
* Enhances disease regions
* Normalizes lighting differences

---

### 4.4 Normalization

Pixel values are converted from:

```text
0 – 255
```

to

```text
0 – 1
```

This improves neural network stability and training consistency.

---

# Deep Learning Model

## Model Type

The Crop Scanner uses:

```text
MobileNetV2
```

which is a lightweight Convolutional Neural Network (CNN).

The model is optimized for:

* High accuracy
* Fast inference
* Low memory usage
* Mobile and edge deployment

---

## Why MobileNetV2?

Traditional CNN architectures are computationally expensive.

MobileNetV2 introduces:

* Depthwise Separable Convolutions
* Inverted Residual Blocks
* Linear Bottlenecks

These techniques significantly reduce computation while maintaining high classification accuracy.

---

## Transfer Learning

Instead of training a CNN from scratch, the project uses Transfer Learning.

The base MobileNetV2 model was originally trained on the ImageNet dataset.

This pretrained knowledge enables the network to understand:

* Shapes
* Edges
* Textures
* Patterns

The model is then fine-tuned using the crop disease dataset.

This approach:

* Reduces training time
* Improves accuracy
* Requires fewer training images

---

# Neural Network Architecture

```text
Input Image (224×224×3)
        ↓
MobileNetV2 Backbone
        ↓
Global Average Pooling
        ↓
Dense Layer (512 Neurons)
        ↓
Batch Normalization
        ↓
ReLU Activation
        ↓
Dropout (0.4)
        ↓
Dense Layer (256 Neurons)
        ↓
Batch Normalization
        ↓
ReLU Activation
        ↓
Dropout (0.3)
        ↓
Softmax Output Layer
```

---

## Feature Extraction

The CNN automatically learns visual features such as:

* Disease spots
* Lesions
* Texture changes
* Leaf discoloration
* Pattern abnormalities
* Damage regions

Unlike traditional machine learning, no manual feature engineering is required.

---

# Disease Classification

The output layer produces probability scores for each disease class.

Example:

```text
Rust                87.3%
Anthracnose          5.1%
Black Rot            3.8%
Others               3.8%
```

The class with the highest probability becomes the final prediction.

---

# Test Time Augmentation (TTA)

To improve prediction reliability, the system performs Test Time Augmentation.

Instead of predicting once, five image variants are generated:

1. Original Image
2. Horizontal Flip
3. Rotation (+10°)
4. Rotation (-10°)
5. Brightness Enhanced Image

Predictions from all variants are averaged.

Benefits:

* Reduces prediction noise
* Improves stability
* Increases robustness to camera angle variations

---

# Confidence Validation

The system validates prediction confidence before returning results.

```text
Confidence < 50%
```

Result:

```text
Uncertain Prediction
```

The user is requested to capture a better image.

This prevents incorrect disease recommendations.

---

# Severity Analysis

After disease detection, the system estimates disease severity.

Outputs include:

* Damage Percentage
* Severity Level
* Spray Recommendation

Severity Levels:

| Damage Percentage | Severity |
| ----------------- | -------- |
| < 30%             | Low      |
| 30% – 60%         | Medium   |
| > 60%             | High     |

This information is used for automated decision making.

---

# IoT Integration

If a disease is detected and spraying is recommended:

```text
Spring Boot
      ↓
Blynk API
      ↓
ESP32
      ↓
Relay Module
      ↓
Sprayer Activation
```

The IoT layer automates crop treatment actions based on AI predictions.

---

# Technologies Used

## Frontend

* Flutter

## Backend

* Spring Boot

## AI Service

* Python
* TensorFlow
* Keras
* OpenCV
* NumPy

## Deep Learning

* MobileNetV2
* Transfer Learning
* CNN Architecture

## IoT

* ESP32
* Blynk
* Relay Module
* Water Sprayer

---

# Conclusion

Crop Scanner combines Deep Learning, Computer Vision, Backend Services, and IoT Automation into a unified agricultural assistance platform.

The system detects crop diseases from leaf images, estimates severity, recommends actions, and can automatically trigger spraying operations through connected IoT devices.

By combining MobileNetV2-based disease classification with real-time IoT integration, the platform provides a scalable and intelligent crop monitoring solution for precision agriculture.
