import java.io.FileInputStream
import java.util.Properties

/// 固定发布签名的本机私有配置，不得提交 keystore 或密码文件。
val releaseSigningProperties = Properties()
val releaseSigningPropertiesFile = rootProject.file("key.properties")

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
    namespace = "io.legado.flutter"
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
        // Flutter 新应用使用独立标识，与原应用 io.legato.kazusa 并存。
        applicationId = "io.legado.flutter"
        // 与原 Android 项目保持一致的最低系统版本。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            /// keystore 路径及密码均来自未纳入 Git 的 android/key.properties。
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
            // M1 暂用模板调试签名；发布签名必须由用户在后续交付阶段配置。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
