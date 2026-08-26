plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.semay.smssender"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.semay.smssender"
        // 24 covers every handset worth using as a sender and keeps
        // SubscriptionManager (22+) available without compat branches.
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        viewBinding = true
    }

    buildTypes {
        release {
            // Sideloaded, not published — Play rejects SEND_SMS for anything
            // that is not the user's default SMS app, so there is no store
            // listing to sign for. Debug keys keep `assembleRelease` working;
            // swap in a real keystore before handing APKs to anyone.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // OkHttp for the relay WebSocket: automatic ping frames and a sane
    // reconnect story, neither of which the platform WebSocket gives us.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
