plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_blind_watermark_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flutter_blind_watermark_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // 64-bit only (user decision): virtually all devices since ~2017
            // are arm64-v8a; dropping armeabi-v7a saves the 32-bit ONNX
            // Runtime binary (~23MB) and the v7a FFI build.
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // 64-bit only (user decision): strip x86/x86_64 (emulator-only,
            // ~34MB) and armeabi-v7a (~23MB) native libs from the APK.
            // (The Flutter Gradle plugin resets ndk.abiFilters to all ABIs,
            // so packaging excludes are the reliable filter for engine libs.)
            excludes += listOf(
                "**/x86_64/*.so",
                "**/x86/*.so",
                "**/armeabi-v7a/*.so",
            )
        }
    }
}

// No Java dependencies: the WAM inference engine lives in the FFI library
// (src/wam_ort.cpp) and talks to the ONNX Runtime C API directly via
// dlopen("libonnxruntime.so"). The .so (1.29.0) is vendored under
// src/main/jniLibs/ — the previous ai.onnxruntime Java/JNI bridge aborted
// with SIGABRT inside sess.run on Android 16 (ART JNI fatal), which is why
// the whole Java inference layer was removed.
dependencies {
}

flutter {
    source = "../.."
}
