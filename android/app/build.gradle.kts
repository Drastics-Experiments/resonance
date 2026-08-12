import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val releaseKeystorePath = providers.environmentVariable("RESONANCE_ANDROID_KEYSTORE_PATH").orNull
val releaseKeystorePassword = providers.environmentVariable("RESONANCE_ANDROID_KEYSTORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("RESONANCE_ANDROID_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("RESONANCE_ANDROID_KEY_PASSWORD").orNull
val developmentInstanceSuffix = providers.gradleProperty("resonanceInstanceSuffix").orNull
    ?.takeIf { it.matches(Regex("\\.worktree\\.w[a-f0-9]{12}")) }
val developmentInstanceName = providers.gradleProperty("resonanceInstanceName").orNull
    ?.takeIf { it.matches(Regex("[A-Za-z0-9 ._\\-\\[\\]]{1,100}")) }
val releaseSigningValues = listOf(
    releaseKeystorePath,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val hasReleaseSigning = releaseSigningValues.all { !it.isNullOrBlank() }
if (releaseSigningValues.any { !it.isNullOrBlank() } && !hasReleaseSigning) {
    throw GradleException("All Resonance Android release-signing environment variables must be provided together.")
}

android {
    namespace = "mov.unblocked.resonance"
    compileSdk = 36

    defaultConfig {
        applicationId = "mov.unblocked.resonance"
        minSdk = 26
        targetSdk = 36
        versionCode = 17
        versionName = "2.0.0"

        vectorDrawables.useSupportLibrary = true
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(requireNotNull(releaseKeystorePath))
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("debug") {
            if (developmentInstanceSuffix != null) {
                applicationIdSuffix = developmentInstanceSuffix
            }
            manifestPlaceholders["resonanceAppLabel"] = developmentInstanceName ?: "Resonance"
        }
        getByName("release") {
            isMinifyEnabled = false
            manifestPlaceholders["resonanceAppLabel"] = "Resonance"
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging.resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
}

kotlin {
    compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.05.00")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
    implementation("androidx.media3:media3-session:1.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("com.clerk:clerk-android-ui:1.0.39")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
