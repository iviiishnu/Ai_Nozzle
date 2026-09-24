plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Java 17: uvccamera uses records, and AGP only emits the record-desugaring
    // synthetics in debug builds when the app's language level is >= 14.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.flutter_app"
        // tflite_flutter requires minSdk 26 (Android 8.0)
        minSdk = 26
        // flutter_uvc_camera checks legacy storage permission during startup.
        // Its Android implementation requires the legacy target behavior.
        targetSdk = 27
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// No manual tensorflow-lite dependency needed.
// tflite_flutter 0.12.1 downloads and links LiteRT 1.4.0 automatically
// via its own android/build.gradle. Adding it manually here causes
// duplicate class conflicts.

flutter {
    source = "../.."
}

