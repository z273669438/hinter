plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.hinter.hinter"
    // permission_handler 13.x 的 AAR 元数据要求 compileSdk >= 37
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    // 内置模型资产不压缩存储:解包更快,避免 173MB 在 APK 内反复 inflate
    androidResources {
        noCompress += listOf("onnx", "txt")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hinter.hinter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // ML Kit 人脸检测(bundled 模型,离线,约 +6MB)
    implementation("com.google.mlkit:face-detection:16.1.6")
    // ML Kit FaceMesh 478 点人脸网格(替代 boundingBox 做美颜掩码跟踪)
    implementation("com.google.mlkit:face-mesh-detection:16.0.0-beta3")
}

flutter {
    source = "../.."
}
