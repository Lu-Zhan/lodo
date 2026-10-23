package com.lodo.app.ui.health

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.CancellationSignal
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import com.lodo.app.data.dbl
import com.lodo.app.ui.L
import com.lodo.app.ui.countdown.SwitchRow
import kotlinx.coroutines.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.round

/** 默认不联网、不定位。只有取整至两位小数的坐标发给 Open-Meteo,不携带健康数据。 */
@Composable
internal fun EnvironmentPanel(vm: HealthJournalViewModel) {
    val context = vm.app
    val prefs = remember { context.getSharedPreferences("environment", Context.MODE_PRIVATE) }
    var enabled by remember { mutableStateOf(prefs.getBoolean("enabled", false)) }
    var latitude by remember { mutableStateOf(prefs.getString("latitude", "").orEmpty()) }
    var longitude by remember { mutableStateOf(prefs.getString("longitude", "").orEmpty()) }
    var cache by remember { mutableStateOf(runCatching { JSONObject(prefs.getString("cache", "").orEmpty()) }.getOrNull()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }
    fun refresh(locate: Boolean) {
        job?.cancel()
        job = scope.launch {
            loading = true; error = null
            try {
                val position = if (locate) withTimeout(20000) { approximatePosition(context) } else latitude.toDouble() to longitude.toDouble()
                require(position.first.isFinite() && position.second.isFinite() && position.first in -90.0..90.0 && position.second in -180.0..180.0) { "请输入有效经纬度" }
                val lat = String.format(Locale.ROOT, "%.2f", round(position.first * 100) / 100)
                val lon = String.format(Locale.ROOT, "%.2f", round(position.second * 100) / 100)
                latitude = lat; longitude = lon
                prefs.edit().putString("latitude", lat).putString("longitude", lon).apply()
                suspend fun fetch(address: String): JSONObject = withContext(Dispatchers.IO) {
                    val connection = URL(address).openConnection() as HttpURLConnection
                    connection.connectTimeout = 15000; connection.readTimeout = 20000
                    try {
                        require(connection.responseCode in 200..299) { "获取数据失败(${connection.responseCode})" }
                        val bytes = java.io.ByteArrayOutputStream().use { output ->
                            connection.inputStream.use { input ->
                                val buffer = ByteArray(8192)
                                while (true) {
                                    val n = input.read(buffer); if (n < 0) break
                                    require(output.size() + n <= 1024 * 1024) { "天气数据过大" }
                                    output.write(buffer, 0, n)
                                }
                            }; output.toByteArray()
                        }
                        JSONObject(bytes.toString(Charsets.UTF_8)).also { require(!it.optBoolean("error")) { it.optString("reason", "获取数据失败") } }
                    } finally { connection.disconnect() }
                }
                // 两条数据互不阻断;一条失败时保留它的旧缓存并明确显示时间。
                val old = cache?.takeIf { it.optString("latitude") == lat && it.optString("longitude") == lon }
                val next = JSONObject(old?.toString() ?: "{}").put("latitude", lat).put("longitude", lon)
                val failures = mutableListOf<String>()
                try {
                    next.put("weather", fetch("https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min&hourly=temperature_2m&timezone=auto&forecast_days=4"))
                    next.put("weatherAt", System.currentTimeMillis())
                } catch (e: CancellationException) { throw e } catch (e: Exception) { failures += "天气:${e.message}" }
                try {
                    next.put("air", fetch("https://air-quality-api.open-meteo.com/v1/air-quality?latitude=$lat&longitude=$lon&current=us_aqi,pm2_5,pm10,ozone,nitrogen_dioxide&hourly=us_aqi&timezone=auto&forecast_days=2"))
                    next.put("airAt", System.currentTimeMillis())
                } catch (e: CancellationException) { throw e } catch (e: Exception) { failures += "空气质量:${e.message}" }
                ensureActive()
                if (enabled) { cache = next; prefs.edit().putString("cache", next.toString()).apply() }
                error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n")
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message ?: "获取失败,可手动填写经纬度" }
            finally { loading = false }
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted && enabled) refresh(true) else error = L("没有位置权限,可手动填写经纬度。", "Location denied. You can enter coordinates manually.")
    }
    SwitchRow(L("天气与空气质量", "Weather & air quality"), enabled) { on ->
        enabled = on; prefs.edit().putBoolean("enabled", on).apply()
        if (!on) { job?.cancel(); loading = false; cache = null; prefs.edit().remove("cache").apply() }
    }
    if (!enabled) { Text(L("开启后才会取位置和联网,不发送任何健康数据。", "Enable to use location and network. No health data is sent.")); return }
    Text(L("只发送约 1 公里精度的位置。空气质量为美标 EPA AQI、模型预报,非监测站实测。", "Only approximate coordinates are sent. EPA AQI is a model forecast, not station measurements."), style = MaterialTheme.typography.bodySmall)
    Row(horizontalArrangement = Arrangement.spacedBy(androidx.compose.ui.unit.Dp(8f))) {
        OutlinedTextField(latitude, { latitude = it }, label = { Text(L("纬度", "Latitude")) }, modifier = Modifier.weight(1f), singleLine = true)
        OutlinedTextField(longitude, { longitude = it }, label = { Text(L("经度", "Longitude")) }, modifier = Modifier.weight(1f), singleLine = true)
    }
    Row {
        TextButton(onClick = {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED) refresh(true)
            else permission.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
        }, enabled = !loading) { Text(L("获取位置并刷新", "Locate & refresh")) }
        TextButton(onClick = { refresh(false) }, enabled = !loading) { Text(L("按坐标刷新", "Refresh coordinates")) }
    }
    if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    cache?.let { saved ->
        saved.optJSONObject("weather")?.let { weather ->
            val current = weather.optJSONObject("current")
            Text("${current?.dbl("temperature_2m") ?: "—"} °C · ${weatherCondition(current?.optInt("weather_code", -1) ?: -1)}")
            Text(L("天气更新: ", "Weather updated: ") + java.time.Instant.ofEpochMilli(saved.optLong("weatherAt")).atZone(java.time.ZoneId.systemDefault()).toLocalDateTime().toString())
            weather.optJSONObject("daily")?.let { daily ->
                val times = daily.optJSONArray("time")
                for (i in 0 until minOf(times?.length() ?: 0, 4)) Text("${times!!.optString(i)} · ${daily.optJSONArray("temperature_2m_min")?.opt(i)} — ${daily.optJSONArray("temperature_2m_max")?.opt(i)} °C")
            }
        }
        saved.optJSONObject("air")?.optJSONObject("current")?.dbl("us_aqi")?.let { aqi ->
            val category = aqiCategory(aqi.toInt())
            Text("AQI ${aqi.toInt()} · ${category.first}")
            Text(category.second)
            Text(L("空气更新: ", "Air updated: ") + java.time.Instant.ofEpochMilli(saved.optLong("airAt")).atZone(java.time.ZoneId.systemDefault()).toLocalDateTime().toString())
        }
        Text(L("数据来源:Open-Meteo / CAMS;天气使用 Open-Meteo。", "Sources: Open-Meteo / CAMS. Weather: Open-Meteo."), style = MaterialTheme.typography.bodySmall)
    }
}
private suspend fun approximatePosition(context: Context): Pair<Double, Double> = suspendCancellableCoroutine { continuation ->
    val manager = context.getSystemService(LocationManager::class.java)
    val signal = CancellationSignal()
    continuation.invokeOnCancellation { signal.cancel() }
    try {
        manager.getCurrentLocation(LocationManager.NETWORK_PROVIDER, signal, context.mainExecutor) { location ->
            if (continuation.isActive) if (location == null) continuation.resumeWithException(IllegalStateException("无法定位,可手动填写经纬度")) else continuation.resume(location.latitude to location.longitude)
        }
    } catch (e: Exception) { if (continuation.isActive) continuation.resumeWithException(e) }
}
private fun weatherCondition(code: Int): String = when (code) {
    0 -> "晴"; 1, 2 -> "多云"; 3 -> "阴"; 45, 48 -> "雾"; in 51..67, in 80..82 -> "雨"; in 71..77, 85, 86 -> "雪"; in 95..99 -> "雷雨"; else -> "—"
}
internal fun aqiCategory(aqi: Int): Pair<String, String> = when {
    aqi < 51 -> "优" to "空气很好,适合户外活动。"
    aqi < 101 -> "良" to "空气尚可,极少数敏感的人减少长时间户外剧烈运动。"
    aqi < 151 -> "对敏感人群不健康" to "儿童、老人和有呼吸道疾病的人减少户外剧烈运动。"
    aqi < 201 -> "不健康" to "减少户外活动,外出建议戴口罩。"
    aqi < 301 -> "非常不健康" to "尽量待在室内,关好门窗。"
    else -> "危险" to "避免外出,开启空气净化。"
}
