plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase plugin'ini buraya ekliyoruz:
    id("com.google.gms.google-services")
}

android {
    namespace = "com.ahmeteguven.kpss_tarih_soru_bankasi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // --- SİYAH EKRAN ÇÖZÜMÜ (Kotlin DSL Formatı) ---
        isCoreLibraryDesugaringEnabled = true
        // ----------------------------------------------
        
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.ahmeteguven.kpss_tarih_soru_bankasi"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // --- EKLENEN KISIM: Kod küçültme ve ProGuard ---
            isMinifyEnabled = false  // Kodu küçült
            isShrinkResources = false // Gereksiz kaynakları sil
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro" // Az önce oluşturduğumuz dosyayı oku
            )
        }
    }
}

flutter {
    source = "../.."
}

// --- DESUGARING KÜTÜPHANESİ (Parantezli olmalı) ---
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}