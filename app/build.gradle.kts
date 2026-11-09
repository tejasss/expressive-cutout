plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val releaseStoreFile: String? =
    project.findProperty("RELEASE_STORE_FILE") as String? ?: System.getenv("RELEASE_STORE_FILE")
val hasReleaseKeystore = releaseStoreFile != null && file(releaseStoreFile).exists()

android {
    namespace = "com.ekoehler.expressivecutout"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.ekoehler.expressivecutout"
        minSdk = 29
        targetSdk = 35
        versionCode = 7
        versionName = "0.4.0-beta"
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                storeFile = file(releaseStoreFile!!)
                storePassword = project.findProperty("RELEASE_STORE_PASSWORD") as String?
                    ?: System.getenv("RELEASE_STORE_PASSWORD")
                keyAlias = project.findProperty("RELEASE_KEY_ALIAS") as String?
                    ?: System.getenv("RELEASE_KEY_ALIAS")
                keyPassword = project.findProperty("RELEASE_KEY_PASSWORD") as String?
                    ?: System.getenv("RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKeystore) "release" else "debug")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.savedstate)
    implementation(libs.androidx.datastore.preferences)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.lottie.compose)
    implementation(libs.haze)

    implementation(libs.shizuku.api)
    implementation(libs.shizuku.provider)
    implementation(libs.hiddenapibypass)

    testImplementation(libs.junit)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation("junit:junit:4.13.2")
}
