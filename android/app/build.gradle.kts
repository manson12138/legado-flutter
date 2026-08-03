import java.io.FileInputStream
import java.util.Properties

/// 固定发布签名的本机私有配置，不得提交 keystore 或密码文件。
val releaseSigningProperties = Properties()
val releaseSigningPropertiesFile = rootProject.file("pagenest-signing.properties")

if (!releaseSigningPropertiesFile.isFile) {
    throw GradleException("缺少 Android 发布签名配置：${releaseSigningPropertiesFile.absolutePath}")
}

FileInputStream(releaseSigningPropertiesFile).use(releaseSigningProperties::load)

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.contradiction.pagenest"
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
        // PageNest 使用全新独立标识，与旧 Flutter 包和原 Android 应用并存。
        applicationId = "com.contradiction.pagenest"
        // 与原 Android 项目保持一致的最低系统版本。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // MMKV 2.x 已移除 32 位原生库，只交付 ARM64 真机和 x86_64 模拟器构建。
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            /// keystore 路径及密码均来自未纳入 Git 的 android/pagenest-signing.properties。
            keyAlias = releaseSigningProperties.getProperty("keyAlias")
            keyPassword = releaseSigningProperties.getProperty("keyPassword")
            storeFile = releaseSigningProperties.getProperty("storeFile")?.let(::file)
            storePassword = releaseSigningProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        debug {
            /// 调试包也使用固定发布证书，确保可与 release 包覆盖安装。
            signingConfig = signingConfigs.getByName("release")
        }

        release {
            // debug/release 共用 PageNest 新发布证书，保证本机覆盖安装的签名身份稳定。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
