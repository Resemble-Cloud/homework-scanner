group = "org.homeworkscanner.fairscan_engine"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.homeworkscanner.fairscan_engine"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // LiteRT is only reliable from API 26 (see FairScan's app/build.gradle.kts).
        minSdk = 26
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnit()
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Same engine stack as FairScan: OpenCV AAR with native libs, LiteRT for the
    // segmentation model, litert-support for TensorImage/ImageProcessor helpers.
    implementation("org.opencv:opencv:4.12.0")
    implementation("com.google.ai.edge.litert:litert:1.4.1")
    implementation("com.google.ai.edge.litert:litert-support:1.4.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.assertj:assertj-core:3.27.7")
}
