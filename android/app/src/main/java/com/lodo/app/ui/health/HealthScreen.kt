package com.lodo.app.ui.health

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.DirectionsRun
import androidx.compose.material.icons.outlined.DirectionsWalk
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.MonitorHeart
import androidx.compose.material.icons.outlined.MonitorWeight
import androidx.compose.material.icons.outlined.NoteAdd
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.HealthMetricKind
import com.lodo.app.core.HealthReport
import com.lodo.app.data.MemoryEntity
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.memory.MemoryComposeSheet
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs

class HealthViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp
    val repo get() = app.health
    var report by mutableStateOf<HealthReport?>(null)
        private set
    var analysis by mutableStateOf<DeepSeekClient.HealthAnalysis?>(null)
        private set
    var analyzing by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
    var saving by mutableStateOf(false)
        private set

    fun load() = viewModelScope.launch { report = app.health.report(28) }
    fun enable(on: Boolean) = viewModelScope.launch { app.settings.setHealthEnabled(on) }

    /** 只发汇总统计给 AI(日均/最近一天/环比),逐条样本不出数据层(同 iOS 隐私口径)。 */
    fun analyze() = viewModelScope.launch {
        val r = report ?: return@launch
        analyzing = true
        error = null
        try {
            val notes = app.memoryRepository.all().filter { it.tagsList.contains(MemoryEntity.healthTagName) }.take(8)
                .joinToString("\n") { "${it.title}:${it.summary}" }.ifBlank { null }
            analysis = DeepSeekClient.analyzeHealth(app.settings.aiConfig(), r.promptSummary(), notes)
        } catch (e: Exception) {
            error = e.message
        } finally { analyzing = false }
    }

    fun saveNote(text: String, done: () -> Unit) = viewModelScope.launch {
        saving = true
        runCatching { app.memoryRepository.saveText(app.settings.aiConfig(), text, listOf(MemoryEntity.healthTagName)) }
        saving = false
        done()
    }
}

private fun icon(kind: HealthMetricKind): ImageVector = when (kind) {
    HealthMetricKind.STEPS -> Icons.Outlined.DirectionsWalk
    HealthMetricKind.ACTIVE_ENERGY -> Icons.Outlined.LocalFireDepartment
    HealthMetricKind.EXERCISE_MINUTES -> Icons.Outlined.DirectionsRun
    HealthMetricKind.SLEEP_HOURS -> Icons.Outlined.Bedtime
    HealthMetricKind.RESTING_HEART_RATE -> Icons.Outlined.Favorite
    HealthMetricKind.HRV -> Icons.Outlined.MonitorHeart
    HealthMetricKind.BODY_MASS -> Icons.Outlined.MonitorWeight
}

private fun title(kind: HealthMetricKind) = when (kind) {
    HealthMetricKind.STEPS -> L("步数", "Steps")
    HealthMetricKind.ACTIVE_ENERGY -> L("活动能量", "Active energy")
    HealthMetricKind.EXERCISE_MINUTES -> L("锻炼时长", "Exercise")
    HealthMetricKind.SLEEP_HOURS -> L("睡眠", "Sleep")
    HealthMetricKind.RESTING_HEART_RATE -> L("静息心率", "Resting heart rate")
    HealthMetricKind.HRV -> L("心率变异性", "HRV")
    HealthMetricKind.BODY_MASS -> L("体重", "Weight")
}

private fun unit(kind: HealthMetricKind) = when (kind) {
    HealthMetricKind.STEPS -> L("步", "steps")
    HealthMetricKind.ACTIVE_ENERGY -> L("千卡", "kcal")
    HealthMetricKind.EXERCISE_MINUTES -> L("分钟", "min")
    HealthMetricKind.SLEEP_HOURS -> L("小时", "h")
    HealthMetricKind.RESTING_HEART_RATE -> L("次/分", "bpm")
    HealthMetricKind.HRV -> L("毫秒", "ms")
    HealthMetricKind.BODY_MASS -> L("公斤", "kg")
}

/**
 * 「健康」页,对应 iOS HealthView:Health Connect 只读,总开关默认关(关着时一个请求都不发)。
 * 指标卡(日均/最近一天/环比 + 最近 14 天柱状)、AI 分析(只发汇总统计)、「记一笔」进记忆库打「健康」。
 */
@Composable
fun HealthScreen(vm: HealthViewModel = viewModel()) {
    val settings = LocalSettings.current
    val context = LocalContext.current
    var granted by remember { mutableStateOf<Set<String>?>(null) }
    var compose by remember { mutableStateOf(false) }
    var refresh by remember { mutableStateOf(0) }
    // 回调里的集合不一定可靠(「全部允许」时实测为空),回来后统一重新查一次授权。
    val request = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) {
        vm.enable(true)
        refresh++
    }
    LaunchedEffect(settings.healthEnabled, refresh) {
        if (settings.healthEnabled && vm.repo.isAvailable) {
            granted = vm.repo.grantedPermissions()
            vm.load()
        }
    }
    LodoPage(
        title = L("健康", "Health"),
        focus = AgentFocus(AgentPageFocus.HEALTH),
        askPrompt = L("最近身体怎么样?", "How am I doing lately?"),
        actions = { IconButton(onClick = { compose = true }) { Icon(Icons.Outlined.NoteAdd, L("记一笔", "Add a note")) } },
    ) { padding ->
        when {
            !vm.repo.isAvailable -> FullEmpty(Icons.Outlined.FavoriteBorder, L("这台设备没有 Health Connect", "Health Connect isn't available"),
                L("Android 14 起系统自带;更早的系统需要先安装 Health Connect。记一笔健康资料仍然可用。", "Built in on Android 14+; install Health Connect on older versions. Notes still work."), padding) {
                FilledTonalButton(onClick = {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata"))) }
                }) { Text(L("去安装", "Install")) }
            }
            !settings.healthEnabled || granted.isNullOrEmpty() -> FullEmpty(Icons.Outlined.FavoriteBorder, L("开启健康分析", "Turn on health insights"),
                L("只读取步数、睡眠、心率等数据,不会写入;只把日均这类汇总发给 AI,逐条记录不离开手机。", "Read-only. Only daily summaries are sent to AI; raw records never leave the device."), padding) {
                Button(onClick = { request.launch(vm.repo.readPermissions) }) { Text(L("连接 Health Connect", "Connect Health Connect")) }
            }
            else -> {
                val report = vm.report
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
                    top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    item("ai") {
                        Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Filled.AutoAwesome, null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.size(8.dp))
                                    Text(L("AI 分析", "AI analysis"), fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.weight(1f))
                                    if (vm.analyzing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                    else TextButton(onClick = vm::analyze, enabled = report?.isEmpty == false) { Text(if (vm.analysis == null) L("分析", "Analyze") else L("重新分析", "Refresh")) }
                                }
                                vm.analysis?.let { a ->
                                    Text(a.analysis, color = MaterialTheme.colorScheme.onPrimaryContainer)
                                    a.suggestions.forEach { Text("• $it", color = MaterialTheme.colorScheme.onPrimaryContainer) }
                                }
                                vm.error?.let { Text(it, color = LodoColor.critical, style = MaterialTheme.typography.bodySmall) }
                                if (vm.analysis == null && vm.error == null) Text(L("把最近 4 周的汇总交给 AI,说说哪些在变好、哪些要注意。", "Let AI look at your 4-week summary."),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                            }
                        }
                    }
                    if (report == null) item("loading") { Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
                    else if (report.isEmpty) item("empty") {
                        Text(L("最近没有读到健康数据(可能没授权,或没有记录)。", "No health data found (not granted or no records)."),
                            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp))
                    } else items(report.series.filter { it.points.isNotEmpty() }, key = { it.kind.raw }) { s ->
                        MetricCard(report, s.kind)
                    }
                    item("footer") {
                        Text(L("数据来自 Health Connect,只读不写。被拒绝授权和没有数据看起来是一样的,可以在系统设置里调整权限。",
                            "Data comes from Health Connect (read-only). Denied permission looks the same as no data."),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { vm.enable(false) }) { Text(L("关闭健康分析", "Turn off health insights")) }
                    }
                }
            }
        }
    }
    if (compose) MemoryComposeSheet(busy = vm.saving, errorText = null, onSave = { vm.saveNote(it) { compose = false } }, onDismiss = { compose = false })
}

@Composable
private fun MetricCard(report: HealthReport, kind: HealthMetricKind) {
    val points = report.series(kind)?.points?.sortedBy { it.date }?.takeLast(14) ?: return
    val trend = report.trend(kind)
    Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon(kind), null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.size(8.dp))
                Text(title(kind), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                trend?.let { t ->
                    val good = (t >= 0) == kind.higherIsBetter
                    Text((if (t >= 0) "↑ " else "↓ ") + String.format(Locale.ROOT, "%.0f%%", abs(t) * 100),
                        color = if (abs(t) < 0.03) MaterialTheme.colorScheme.onSurfaceVariant else if (good) LodoColor.positive else LodoColor.warning,
                        style = MaterialTheme.typography.labelLarge)
                }
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(kind.format(report.average(kind) ?: 0.0), fontSize = 28.sp, fontWeight = FontWeight.Bold)
                Text(" " + unit(kind) + L(" · 日均", " · daily avg"), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 4.dp))
            }
            val max = points.maxOf { it.value }.coerceAtLeast(0.0001)
            Row(Modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
                points.forEachIndexed { i, p ->
                    Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                        Box(Modifier.fillMaxWidth().fillMaxHeight((p.value / max).toFloat().coerceAtLeast(0.05f))
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = if (i == points.size - 1) 1f else 0.4f), RoundedCornerShape(4.dp)))
                    }
                }
            }
            report.latest(kind)?.let { Text(L("最近一天 ", "Latest ") + kind.format(it) + " " + unit(kind), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
