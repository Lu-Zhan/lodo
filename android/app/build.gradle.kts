plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.lodo.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.lodo.app"
        // 26 → 31:端上 AI(Gemini Nano / AICore,对应 iOS Foundation Models)
        // 的 SDK 硬性要求 minSdk 31,用户已确认接受掉 Android 8.0-11 支持换取
        // 这项能力(见相关讨论)。
        minSdk = 31
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.okhttp)
    // 定时任务(AI 例行任务)执行调度,对应 iOS BGTaskScheduler 那一层。
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // 端上 AI(Gemini Nano),对应 iOS Foundation Models 的 Android 等价物;
    // minSdk 31 硬性要求已在 defaultConfig 里说明。
    implementation("com.google.ai.edge.aicore:aicore:0.0.1-exp01")
    testImplementation(libs.junit)
    // 纯 JVM 单测(不经 Robolectric/仪器化)链接的是 android.jar 里 org.json 的桩实现
    // (所有方法 throw "Stub!"),DeepSeekClient 的 JSON 解析逻辑要测就得在测试
    // classpath 上换成真实实现覆盖掉桩版本。
    testImplementation("org.json:json:20240303")
    debugImplementation(libs.androidx.compose.ui.tooling)
}
