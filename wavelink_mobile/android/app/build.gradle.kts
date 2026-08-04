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
        minSdk = flutter.minSdkVersion
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
