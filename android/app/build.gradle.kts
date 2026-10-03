plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.obstablet.obs_tablet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.obstablet.obs_tablet"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Surface.lockHardwareCanvas (used by the encoder) needs API 23; camera needs 24.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // One fixed key for every build, so a new APK installs as an update over
    // the previous one. The committed test key is only for these sideloaded
    // test builds; for a store release, set OBSPAD_KEYSTORE (and the
    // password/alias variables) to a private key kept out of the repository.
    signingConfigs {
        create("obspad") {
            val custom = System.getenv("OBSPAD_KEYSTORE")
            storeFile = file(custom ?: "obspad-test-signing.p12")
            storeType = if (custom == null) "PKCS12" else (System.getenv("OBSPAD_KEYSTORE_TYPE") ?: "PKCS12")
            storePassword = System.getenv("OBSPAD_KEYSTORE_PASSWORD") ?: "obspad-test"
            keyAlias = System.getenv("OBSPAD_KEY_ALIAS") ?: "obspad"
            keyPassword = System.getenv("OBSPAD_KEY_PASSWORD") ?: "obspad-test"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("obspad")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Generic USB Video Class driver (libusb/libuvc) for HDMI capture cards and
    // webcams on any Android device with USB host (OTG). Apache-2.0.
    implementation("com.herohan:UVCAndroid:1.0.13")
}
