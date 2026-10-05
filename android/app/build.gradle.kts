import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

/** 内置 API key 从 gitignored 的 local.properties 读(同 iOS 的 gitignored BuiltInAPIKey.swift),
 * 没配就是空串,app 里按"没有内置 key"处理,仓库里不出现真实值。 */
val localProps = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun localProp(name: String) = (localProps.getProperty(name) ?: "").replace("\\", "").replace("\"", "")

android {
    namespace = "com.lodo.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.lodo.app"
        // 26 → 31:端上 AI(Gemini Nano / AICore,对应 iOS Foundation Models)
        // 的 SDK 硬性要求 minSdk 31,用户已确认接受掉 Android 8.0-11 支持换取
        // 这项能力(见相关讨论)。
        minSdk = 31
        targetSdk = 36
        versionCode = 2
        versionName = "2.0"
        // 端上 OCR 的原生库只打 64 位(现在的手机都是 arm64,x86_64 给模拟器),APK 小一半。
        buildConfigField("String", "BUILT_IN_DEEPSEEK_KEY", "\"${localProp("lodo.deepseekKey")}\"")
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
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
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
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
    // 菜单/订单截图的端上 OCR(ML Kit 文字识别,模型打包进 APK,不依赖 Play 服务、不上传图片;
    // 中文识别器同时认拉丁字母,日文/韩文菜单另配两个),对应 iOS Vision OCR。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
    // 健康分析:Health Connect(对应 iOS HealthKit),只读、默认关。
    implementation("androidx.health.connect:connect-client:1.1.0")
    // 旅行地图:osmdroid(OpenStreetMap 栅格瓦片,不要 key;安卓上没有苹果 MapKit 那样的系统地图控件,
    // Google Maps SDK 又要 API key),对应 iOS 旅行详情的 Map。
    implementation("org.osmdroid:osmdroid-android:6.1.20")
    testImplementation(libs.junit)
    // 纯 JVM 单测(不经 Robolectric/仪器化)链接的是 android.jar 里 org.json 的桩实现
    // (所有方法 throw "Stub!"),DeepSeekClient 的 JSON 解析逻辑要测就得在测试
    // classpath 上换成真实实现覆盖掉桩版本。
    testImplementation("org.json:json:20240303")
    debugImplementation(libs.androidx.compose.ui.tooling)
}
