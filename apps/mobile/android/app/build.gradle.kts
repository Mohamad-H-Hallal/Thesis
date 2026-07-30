plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun releaseValue(name: String): String? =
    providers.gradleProperty(name)
        .orElse(providers.environmentVariable(name))
        .orNull
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

val releaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val releaseApplicationId = releaseValue("TERRALEB_APPLICATION_ID")
val releaseKeystorePath = releaseValue("TERRALEB_KEYSTORE_PATH")
val releaseKeystorePassword = releaseValue("TERRALEB_KEYSTORE_PASSWORD")
val releaseKeyAlias = releaseValue("TERRALEB_KEY_ALIAS")
val releaseKeyPassword = releaseValue("TERRALEB_KEY_PASSWORD")

if (releaseBuildRequested) {
    val missingReleaseValues = mapOf(
        "TERRALEB_APPLICATION_ID" to releaseApplicationId,
        "TERRALEB_KEYSTORE_PATH" to releaseKeystorePath,
        "TERRALEB_KEYSTORE_PASSWORD" to releaseKeystorePassword,
        "TERRALEB_KEY_ALIAS" to releaseKeyAlias,
        "TERRALEB_KEY_PASSWORD" to releaseKeyPassword,
    ).filterValues { it == null }.keys

    require(missingReleaseValues.isEmpty()) {
        "Release signing is fail-closed. Missing: ${missingReleaseValues.joinToString(", ")}"
    }
    require(
        Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){2,}$")
            .matches(releaseApplicationId!!),
    ) {
        "TERRALEB_APPLICATION_ID must be a valid reverse-DNS application ID."
    }
    require(!releaseApplicationId.lowercase().startsWith("com.example")) {
        "TERRALEB_APPLICATION_ID must not use the com.example placeholder."
    }
    require(file(releaseKeystorePath!!).isFile) {
        "TERRALEB_KEYSTORE_PATH does not identify a readable keystore file."
    }
    require(file("google-services.json").isFile) {
        "Release builds require google-services.json for the final Android application ID."
    }
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.example.lebanese_gis_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Debug builds retain the historical identifier. Release builds must
        // supply the final, non-placeholder identifier through the protected
        // release environment.
        applicationId = releaseApplicationId ?: "com.example.lebanese_gis_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseBuildRequested) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseBuildRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    constraints {
        implementation("net.zetetic:sqlcipher-android:4.17.0") {
            version {
                strictly("4.17.0")
            }
            because("Keep the encrypted offline store on the reviewed SQLCipher release.")
        }
    }
}

flutter {
    source = "../.."
}
