plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.community.community_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.community.community_app"
        // 运行时校验签名证书；改包/重签后客户端会拒绝启动。
        buildConfigField(
            "String",
            "EXPECTED_SIGNATURE_SHA256",
            "\"${System.getenv("EXPECTED_SIGNATURE_SHA256") ?: "412770589c248454e1cb8f81054cf35148852b07b68d319b4690c1c7a3832e62"}\"",
        )
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

    // 密钥只从构建环境注入，绝不写进仓库；旧 JKS 与 liuying2026 已视为泄露。
    val releaseStorePath = System.getenv("ANDROID_KEYSTORE_PATH").orEmpty()
    val hasReleaseKey = releaseStorePath.isNotBlank() && file(releaseStorePath).exists()
    if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) } && !hasReleaseKey) {
        throw GradleException("缺少 release 签名密钥：设置 ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS")
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(releaseStorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD").orEmpty()
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "liuying-release"
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                    ?: System.getenv("ANDROID_KEYSTORE_PASSWORD").orEmpty()
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    buildFeatures {
        buildConfig = true
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
