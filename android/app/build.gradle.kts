plugins {
    alias(libs.plugins.android.application)
}

// The control plane everyone starts on. A debug build can point at a local Rupert instead:
//   ./gradlew installDebug -Prupert.controlPlane=http://10.0.2.2:3000
val controlPlane = providers.gradleProperty("rupert.controlPlane").orElse("https://pos.rupertpos.com").get()

// Release signing comes from outside the repository (see README.md). Without these the release
// bundle is unsigned, which is what Play App Signing's first upload needs to be signed locally.
val keystoreFile = providers.environmentVariable("RUPERT_UPLOAD_KEYSTORE").orNull
val keystorePassword = providers.environmentVariable("RUPERT_UPLOAD_KEYSTORE_PASSWORD").orNull
val keyAlias = providers.environmentVariable("RUPERT_UPLOAD_KEY_ALIAS").orNull
val keyPassword = providers.environmentVariable("RUPERT_UPLOAD_KEY_PASSWORD").orNull
val canSignRelease = listOf(keystoreFile, keystorePassword, keyAlias, keyPassword).all { !it.isNullOrBlank() }

android {
    namespace = "com.rupertpos.rupert"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.rupertpos.rupert"
        minSdk = 28
        targetSdk = 36
        // CI stamps the build number (as the iPhone app does); local builds are 1.
        versionCode = providers.environmentVariable("RUPERT_VERSION_CODE").orElse("1").get().toInt()
        versionName = "1.0.0"
        buildConfigField("String", "CONTROL_PLANE_URL", "\"$controlPlane\"")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (canSignRelease) {
            create("upload") {
                storeFile = file(keystoreFile!!)
                storePassword = keystorePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
            }
        }
    }

    buildTypes {
        debug {
            // Same application ID as release, so launcher shortcuts (res/xml/shortcuts.xml) work in both.
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = if (canSignRelease) signingConfigs.getByName("upload") else null
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Robolectric's Android 16 runtime reaches into JDK internals for shared memory.
            it.jvmArgs("--add-exports=java.base/jdk.internal.access=ALL-UNNAMED", "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED")
        }
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
        // Version bumps are reviewed by hand; they are not build failures.
        disable += setOf("GradleDependency", "AndroidGradlePluginVersion", "NewerVersionAvailable", "OldTargetApi")
        // Hotwire inflates its own progress and error views the same way.
        disable += "InflateParams"
    }

    packaging {
        resources.excludes += setOf("META-INF/*.kotlin_module", "META-INF/versions/**", "DebugProbesKt.bin")
    }
}

/**
 * The iPhone app's path-configuration.json is the one bundled copy of the navigation rules (the
 * server serves the same rules at /native/android/path-configuration.json). It is copied into
 * this app's assets at build time instead of keeping a second copy in the repository.
 */
abstract class CopyPathConfiguration : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val source: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = outputDirectory.get().dir("json").asFile
        target.mkdirs()
        source.get().asFile.copyTo(File(target, "path-configuration.json"), overwrite = true)
    }
}

val copyPathConfiguration = tasks.register<CopyPathConfiguration>("copyPathConfiguration") {
    source.set(rootProject.layout.projectDirectory.file("../ios/Sources/Rupert/Resources/path-configuration.json"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyPathConfiguration, CopyPathConfiguration::outputDirectory)
    }
}

dependencies {
    implementation(libs.hotwire.core)
    implementation(libs.hotwire.navigation.fragments)
    implementation(libs.androidx.biometric)
    implementation(libs.play.services.code.scanner)
    implementation(libs.okhttp)
    implementation(libs.material)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.browser)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.okhttp.mockwebserver)

    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.espresso.core)
}
