plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties

// 加载 release 签名配置
val keystoreProps: Properties? = run {
    val f = rootProject.file("key.properties")
    if (!f.exists()) return@run null
    Properties().also { p -> f.inputStream().use { p.load(it) } }
}

android {
    namespace = "com.wavelink.wavelink_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.wavelink.wavelink_mobile"
        // 显式声明（与 flutter.minSdkVersion 默认值一致，勿隐式依赖）：
        // Oboe/AAudio 在 API 27 以下无 Exclusive 能力，audio-core 会自动
        // 降级 Shared 模式并如实上报，故 24 可正常运行
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystoreProps != null) {
                storeFile = file(keystoreProps!!.getProperty("storeFile"))
                storePassword = keystoreProps!!.getProperty("storePassword")
                keyAlias = keystoreProps!!.getProperty("keyAlias")
                keyPassword = keystoreProps!!.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
