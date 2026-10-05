package com.lodo.app.ui.overview

import android.app.Application
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.AlarmOn
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.DirectionsWalk
import androidx.compose.material.icons.outlined.DonutLarge
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.ShowChart
import androidx.compose.material.icons.outlined.Update
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.CountdownPlan
import com.lodo.app.data.CalendarEvent
import com.lodo.app.data.entry
import com.lodo.app.ui.AppSection
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LocalShell
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.countdown.countdownSpanText
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * 总览模块种类,存储值别改(同 iOS OverviewWidgetKind 的思路)。small = 默认半宽;
 * resizable = 能在小卡/大卡之间切(列表型、AI 长文本只给大卡,时钟只给小卡,同 iOS allowedSizes)。
 */
enum class OverviewKind(val raw: String, val small: Boolean, val icon: ImageVector, val resizable: Boolean = false) {
    NOW("now", true, Icons.Outlined.Schedule),
    NEXT_UP("nextUp", true, Icons.AutoMirrored.Outlined.ArrowForward, resizable = true),
    WEEK("week", true, Icons.Outlined.ShowChart, resizable = true),
    DUE("due", false, Icons.Outlined.NotificationsActive),
    TODAY_TASKS("todayTasks", false, Icons.Outlined.Checklist),
    EVENTS("events", false, Icons.Outlined.CalendarMonth),
    COUNTDOWN("countdown", true, Icons.Outlined.HourglassTop, resizable = true),
    COUNT_UP("countUp", true, Icons.Outlined.Update, resizable = true),
    ROUTINES("routines", false, Icons.Outlined.AlarmOn),
    SUGGESTION("suggestion", false, Icons.Filled.AutoAwesome),
    MEMORIES("memories", false, Icons.Outlined.Bookmarks),
    HEALTH("health", false, Icons.Outlined.FavoriteBorder),
    ACTIVITY_RING("activityRing", true, Icons.Outlined.DonutLarge, resizable = true),
    TODAY_PROGRESS("todayProgress", true, Icons.Outlined.TaskAlt, resizable = true),
    STEP_TREND("stepTrend", false, Icons.Outlined.DirectionsWalk, resizable = true);

    val title get() = when (this) {
        NOW -> L("此刻", "Now")
        NEXT_UP -> L("接下来", "Up next")
        ROUTINES -> L("今日例行", "Today's routines")
        WEEK -> L("本周完成", "This week")
        DUE -> L("已到期提醒", "Due now")
        TODAY_TASKS -> L("今天任务", "Today")
        EVENTS -> L("今日日程", "Events today")
        COUNTDOWN -> L("倒数日", "Countdown")
        COUNT_UP -> L("正数日", "Counting up")
        SUGGESTION -> L("处理建议", "Suggestion")
        MEMORIES -> L("今天的记忆", "Today's memories")
        HEALTH -> L("健康", "Health")
        ACTIVITY_RING -> L("活动圆环", "Activity rings")
        TODAY_PROGRESS -> L("今日进度", "Today's progress")
        STEP_TREND -> L("步数趋势", "Steps")
    }

    companion object {
        /**
         * 布局容错:认不出的丢、重复的留第一个、老布局里没有的新种类补在末尾并显示、
         * 不允许的尺寸改回默认(同 iOS OverviewLayout)。格式 `raw:显示:尺寸`,老格式没有尺寸。
         */
        fun decode(raw: String): List<OverviewEntry> {
            val parsed = raw.split(",").mapNotNull { part ->
                val bits = part.split(":")
                val kind = entries.firstOrNull { it.raw == bits.getOrNull(0) } ?: return@mapNotNull null
                val small = when (bits.getOrNull(2)) { "s" -> true; "l" -> false; else -> kind.small }
                OverviewEntry(kind, bits.getOrNull(1) != "0", if (kind.resizable) small else kind.small)
            }.distinctBy { it.kind }
            return parsed + entries.filter { k -> parsed.none { it.kind == k } }.map { OverviewEntry(it, true, it.small) }
        }

        fun encode(list: List<OverviewEntry>) =
            list.joinToString(",") { "${it.kind.raw}:${if (it.visible) 1 else 0}:${if (it.small) "s" else "l"}" }
    }
}

data class OverviewEntry(val kind: OverviewKind, val visible: Boolean, val small: Boolean)

class OverviewViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp
    val pending = app.database.taskDao().observePending().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val done = app.database.taskDao().observeDone().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val countdowns = app.countdowns.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val memories = app.memoryRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    var events by mutableStateOf<List<CalendarEvent>>(emptyList())
        private set
    var suggestion by mutableStateOf<String?>(null)
        private set
    var memorySummary by mutableStateOf<String?>(null)
        private set
    var health by mutableStateOf<String?>(null)
        private set
    /** 圆环/步数趋势用的健康数据;健康开关关着时一次都不读(同 iOS healthEnabled 门控)。 */
    var healthReport by mutableStateOf<com.lodo.app.core.HealthReport?>(null)
        private set

    fun loadHealth() = viewModelScope.launch {
        healthReport = if (app.settings.snapshot().healthEnabled && app.health.isAvailable) runCatching { app.health.report(7) }.getOrNull() else null
    }

    /** 今天和明天的日程:「今日日程」只取今天,「接下来」要能看到明天一早的。 */
    var upcomingEvents by mutableStateOf<List<CalendarEvent>>(emptyList())
        private set
    /** 今天定时任务跑出来的结果(routine 名 → 结果文字)。 */
    var routineRuns by mutableStateOf<List<Pair<String, String>>>(emptyList())
        private set

    fun loadEvents() = viewModelScope.launch {
        if (app.settings.snapshot().calendarEnabled) {
            val all = app.calendar.events(LocalDate.now(), LocalDate.now().plusDays(1))
            events = all.filter { it.covers(LocalDate.now()) }
            upcomingEvents = all
        }
    }

    fun loadRoutines() = viewModelScope.launch {
        val since = LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val names = app.database.routineDao().observeAll().first().associate { it.uuid to it.prompt }
        routineRuns = app.database.routineDao().runsSince(since).map { (names[it.routineUuid] ?: "") to it.resultText }
    }

    /** AI 三段按天缓存(同 iOS):内容没变就不重新请求,失败不显示。 */
    private suspend fun cached(key: String, material: String, fetch: suspend (com.lodo.app.ai.AIConfig) -> String): String? {
        if (material.isBlank()) return null
        val prefs = app.getSharedPreferences("overview-ai", 0)
        val stamp = LocalDate.now().toString() + material.hashCode()
        if (prefs.getString("$key.stamp", null) == stamp) return prefs.getString("$key.text", null)
        val config = app.settings.aiConfig()
        if (config.apiKey.isNullOrBlank()) return null
        return runCatching { fetch(config) }.getOrNull()?.also {
            prefs.edit().putString("$key.stamp", stamp).putString("$key.text", it).apply()
        }
    }

    fun loadAi(todayLines: String, memoryLines: String) = viewModelScope.launch {
        suggestion = cached("suggestion", todayLines) { DeepSeekClient.suggestTodayHandling(it, todayLines) }
        memorySummary = cached("memories", memoryLines) { DeepSeekClient.summarizeTodayMemories(it, memoryLines) }
        val s = app.settings.snapshot()
        if (s.healthEnabled && app.health.isAvailable) {
            val summary = app.health.report(14).promptSummary()
            health = cached("health", summary) { DeepSeekClient.suggestTodayHealth(it, summary) }
        } else health = null
    }

    fun saveLayout(list: List<OverviewEntry>) = viewModelScope.launch { app.settings.setOverviewLayout(OverviewKind.encode(list)) }
    fun complete(uuid: String) = viewModelScope.launch { app.repository.complete(uuid) }
}

/**
 * 「总览」页,对应 iOS OverviewView:和时间相关的模块网格(小卡半宽、大卡整宽,两列),
 * 右上角「编辑」调整显示和顺序。AI 那几段(处理建议/今天的记忆/健康)按天缓存。
 */
@Composable
fun OverviewScreen(vm: OverviewViewModel = viewModel()) {
    val settings = LocalSettings.current
    val shell = LocalShell.current
    val pending by vm.pending.collectAsStateWithLifecycle()
    val done by vm.done.collectAsStateWithLifecycle()
    val countdowns by vm.countdowns.collectAsStateWithLifecycle()
    val memories by vm.memories.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf(false) }
    val layout = remember(settings.overviewLayout) { OverviewKind.decode(settings.overviewLayout) }
    val now = remember { LocalDateTime.now() }
    val today = now.toLocalDate()
    val due = pending.filter { it.toData().isDue(now) }
    val todayTasks = pending.filter { !it.nextRemindAt.toLocalDate().isAfter(today) }
    val todayMemories = memories.filter { it.createdAt.toLocalDate() == today && !it.isContact }
    val fmt = com.lodo.app.ui.appFormatter("HH:mm")
    LaunchedEffect(Unit) { vm.loadEvents(); vm.loadRoutines() }
    LaunchedEffect(settings.healthEnabled) { vm.loadHealth() }
    LaunchedEffect(todayTasks.size, todayMemories.size) {
        vm.loadAi(
            todayTasks.joinToString("\n") { "${it.title} ${it.nextRemindAt.format(fmt)}" + if (it.toData().isDue(now)) "(已到期未处理)" else "" },
            todayMemories.joinToString("\n") { "${it.title}:${it.summary}" },
        )
    }

    LodoPage(
        title = L("总览", "Overview"),
        focus = AgentFocus(AgentPageFocus.OVERVIEW),
        askPrompt = L("今天怎么安排?", "How's today looking?"),
        actions = { IconButton(onClick = { editing = true }) { Icon(Icons.Outlined.Edit, L("编辑", "Edit")) } },
    ) { padding ->
        val visible = layout.filter { it.visible }.filter { e ->
            when (e.kind) {
                OverviewKind.EVENTS -> settings.calendarEnabled
                OverviewKind.SUGGESTION -> vm.suggestion != null
                OverviewKind.MEMORIES -> vm.memorySummary != null
                OverviewKind.HEALTH -> settings.healthEnabled
                OverviewKind.DUE -> due.isNotEmpty()
                else -> true
            }
        }
        LazyVerticalGrid(
            // 手机两列、宽屏四列;小卡占一格,大卡占两格(手机上就是整行)。
            columns = GridCells.Fixed(if (androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 840) 4 else 2),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 4.dp,
                bottom = padding.calculateBottomPadding() + 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(visible, key = { it.kind.raw }, span = { GridItemSpan(if (it.small) 1 else minOf(2, maxLineSpan)) }) { entry ->
                val kind = entry.kind
                val small = entry.small
                when (kind) {
                    OverviewKind.NOW -> Widget(kind, small = true) {
                        Text(now.format(fmt), fontSize = 40.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                        Text(today.format(com.lodo.app.ui.appFormatter(L("M月d日 EEEE", "EEE, MMM d"))), style = MaterialTheme.typography.bodyMedium)
                        Text(L("还有 ${todayTasks.size} 件任务", "${todayTasks.size} tasks left"), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    OverviewKind.WEEK -> {
                        val monday = today.minusDays((today.dayOfWeek.value - 1).toLong())
                        val counts = (0..6).map { d -> done.count { it.doneAt?.toLocalDate() == monday.plusDays(d.toLong()) } }
                        Widget(kind, small = small) {
                            Text(L("${counts.sum()} 件", "${counts.sum()} done"), fontSize = 28.sp, fontWeight = FontWeight.Bold)
                            Bars(counts, today.dayOfWeek.value - 1)
                        }
                    }
                    OverviewKind.NEXT_UP -> {
                        // 接下来要发生的事:还没到时间的任务和日程合在一起按时间排(同 iOS OverviewNextUpWidget)。
                        val items = (pending.filter { it.nextRemindAt.isAfter(now) }.map { Triple(it.title, it.nextRemindAt, false) } +
                            vm.upcomingEvents.filter { !it.allDay && it.start.isAfter(now) }.map { Triple(it.title, it.start, true) })
                            .sortedBy { it.second }.take(3)
                        Widget(kind, small = small, onClick = { shell.go(if (items.firstOrNull()?.third == true) AppSection.CALENDAR else AppSection.TASKS) }) {
                            val first = items.firstOrNull()
                            if (first == null) Text(L("接下来没有安排", "Nothing coming up"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            else if (small) {
                                Text(relativeLabel(first.second, now), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary, maxLines = 1)
                                Text(first.first, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(if (first.third) Icons.Outlined.CalendarMonth else Icons.Outlined.Checklist, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(Modifier.width(4.dp))
                                    Text(first.second.format(fmt), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            } else items.forEach { (title, at, isEvent) ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(if (isEvent) Icons.Outlined.CalendarMonth else Icons.Outlined.Checklist, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(Modifier.width(8.dp))
                                    Text(title, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(relativeLabel(at, now), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                    OverviewKind.ROUTINES -> Widget(kind) {
                        if (vm.routineRuns.isEmpty()) Text(L("今天还没有定时任务的结果", "No routine results yet today"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        vm.routineRuns.take(3).forEach { (name, text) ->
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                if (name.isNotBlank()) Text(name, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    OverviewKind.DUE -> Widget(kind, onClick = { shell.go(AppSection.TASKS) }) {
                        due.take(4).forEach { TaskLine(it.title, it.nextRemindAt.format(fmt), true) { vm.complete(it.uuid) } }
                    }
                    OverviewKind.TODAY_TASKS -> Widget(kind, onClick = { shell.go(AppSection.TASKS) }) {
                        if (todayTasks.isEmpty()) Text(L("今天没有要做的事了 🎉", "All clear for today 🎉"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        todayTasks.take(5).forEach { TaskLine(it.title, it.nextRemindAt.format(fmt), it.toData().isDue(now)) { vm.complete(it.uuid) } }
                        if (todayTasks.size > 5) Text(L("还有 ${todayTasks.size - 5} 件…", "${todayTasks.size - 5} more…"), style = MaterialTheme.typography.bodySmall)
                    }
                    OverviewKind.EVENTS -> Widget(kind, onClick = { shell.go(AppSection.CALENDAR) }) {
                        if (vm.events.isEmpty()) Text(L("今天没有日程", "No events today"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        vm.events.take(5).forEach { e ->
                            Text((if (e.allDay) L("全天", "All day") else e.start.format(fmt)) + "  " + e.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    OverviewKind.COUNTDOWN -> {
                        val entries = countdowns.map { it.entry() }.filter { !it.archived }
                        val next = CountdownPlan.sorted(entries.filter { !CountdownPlan.isPast(it, now) }, now).firstOrNull()
                        Widget(kind, small = small, onClick = { shell.go(AppSection.COUNTDOWN) }) {
                            if (next == null) Text(L("没有要到来的日子", "Nothing upcoming"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            else {
                                val (n, label) = countdownSpanText(CountdownPlan.primary(next, now), precise = false)
                                Text(next.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
                                Text(n, fontSize = 30.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                                Text(label, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                    OverviewKind.COUNT_UP -> {
                        val up = CountdownPlan.countUps(countdowns.map { it.entry() }, now).firstOrNull()
                        Widget(kind, small = small, onClick = { shell.go(AppSection.COUNTDOWN) }) {
                            if (up == null) Text(L("还没有纪念日", "No anniversaries"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            else {
                                val (n, _) = countdownSpanText(CountdownPlan.primary(up.entry, now), precise = false)
                                Text(up.entry.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
                                Text(n, fontSize = 30.sp, fontWeight = FontWeight.Bold, color = LodoColor.positive)
                                up.next?.let { m ->
                                    Text(L("${m.daysAway} 天后", "in ${m.daysAway} d") + when (val k = m.kind) {
                                        is CountdownPlan.MilestoneKind.Anniversary -> L("满 ${k.years} 周年", " · ${k.years} yr")
                                        is CountdownPlan.MilestoneKind.DayCount -> L("满 ${k.days} 天", " · ${k.days} d")
                                        else -> ""
                                    }, style = MaterialTheme.typography.bodySmall)
                                }
                            }
                        }
                    }
                    OverviewKind.SUGGESTION -> Widget(kind) { Text(vm.suggestion ?: "", style = MaterialTheme.typography.bodyLarge) }
                    OverviewKind.MEMORIES -> Widget(kind, onClick = { shell.go(AppSection.MEMORY) }) { Text(vm.memorySummary ?: "", style = MaterialTheme.typography.bodyLarge) }
                    OverviewKind.HEALTH -> Widget(kind, onClick = { shell.go(AppSection.HEALTH) }) {
                        Text(vm.health ?: L("打开健康页看看最近的数据", "Open Health to see your recent data"), style = MaterialTheme.typography.bodyLarge)
                    }
                    OverviewKind.ACTIVITY_RING -> Widget(kind, small = small, onClick = { shell.go(AppSection.HEALTH) }) {
                        val report = vm.healthReport
                        if (!settings.healthEnabled || report == null) HealthGuide()
                        else ActivityRings(com.lodo.app.core.OverviewCharts.rings(report, today), showLegend = !small)
                    }
                    OverviewKind.TODAY_PROGRESS -> {
                        val doneToday = done.count { it.doneAt?.toLocalDate() == today }
                        val p = com.lodo.app.core.OverviewCharts.todayProgress(doneToday, todayTasks.size)
                        Widget(kind, small = small, onClick = { shell.go(AppSection.TASKS) }) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                Box(contentAlignment = Alignment.Center, modifier = Modifier.size(84.dp)) {
                                    androidx.compose.material3.CircularProgressIndicator(
                                        progress = { (p.fraction ?: 0.0).toFloat() }, modifier = Modifier.fillMaxSize(), strokeWidth = 10.dp,
                                        trackColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
                                        strokeCap = androidx.compose.ui.graphics.StrokeCap.Round,
                                    )
                                    Text(p.fraction?.let { "${(it * 100).toInt()}%" } ?: "–", fontWeight = FontWeight.Bold)
                                }
                                if (!small) Text(L("今天完成 ${p.done} 件,还剩 ${p.total - p.done} 件", "${p.done} done, ${p.total - p.done} to go"),
                                    style = MaterialTheme.typography.bodyLarge)
                            }
                            if (small) Text(L("${p.done}/${p.total} 件", "${p.done}/${p.total}"), style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    OverviewKind.STEP_TREND -> Widget(kind, small = small, onClick = { shell.go(AppSection.HEALTH) }) {
                        val report = vm.healthReport
                        if (!settings.healthEnabled || report == null) HealthGuide()
                        else {
                            val trend = com.lodo.app.core.OverviewCharts.stepTrend(report, today)
                            val latest = trend.lastOrNull { it.second != null }?.second
                            Text(latest?.let { L("${it.toInt()} 步", "${it.toInt()} steps") } ?: L("最近没有步数", "No recent steps"),
                                fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            NullableBars(trend.map { it.second }, trend.size - 1)
                        }
                    }
                }
            }
        }
    }
    if (editing) LayoutEditor(layout, onSave = { vm.saveLayout(it) }, onDismiss = { editing = false })
}

@Composable
private fun Widget(kind: OverviewKind, small: Boolean = false, onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    val mod = Modifier.fillMaxWidth().heightIn(min = if (small) 150.dp else 0.dp)
    val colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
    val body: @Composable () -> Unit = {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(kind.icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(kind.title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            }
            content()
        }
    }
    if (onClick != null) Card(onClick = onClick, shape = RoundedCornerShape(24.dp), colors = colors, modifier = mod) { body() }
    else Card(shape = RoundedCornerShape(24.dp), colors = colors, modifier = mod) { body() }
}

@Composable
private fun TaskLine(title: String, time: String, overdue: Boolean, onComplete: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onComplete, modifier = Modifier.size(32.dp)) {
            Icon(Icons.Outlined.Circle, L("完成", "Complete"), tint = if (overdue) LodoColor.critical else MaterialTheme.colorScheme.outline, modifier = Modifier.size(20.dp))
        }
        Text(title, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(time, style = MaterialTheme.typography.bodySmall, color = if (overdue) LodoColor.critical else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** 本周完成:七根柱子(系统形状摆出来,不是自绘)。 */
@Composable
private fun Bars(counts: List<Int>, todayIndex: Int) {
    val max = (counts.maxOrNull() ?: 0).coerceAtLeast(1)
    Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
        counts.forEachIndexed { i, c ->
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                Box(Modifier.fillMaxWidth().fillMaxHeight((c.toFloat() / max).coerceAtLeast(0.06f))
                    .background(if (i == todayIndex) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                        RoundedCornerShape(6.dp)))
            }
        }
    }
}

/** 「20 分钟后」「明天 09:00」这类相对时间(同 iOS relativeTimeLabel)。 */
private fun relativeLabel(at: LocalDateTime, now: LocalDateTime): String {
    val minutes = java.time.Duration.between(now, at).toMinutes()
    return when {
        minutes < 1 -> L("马上", "Now")
        minutes < 60 -> L("$minutes 分钟后", "in $minutes min")
        at.toLocalDate() == now.toLocalDate() -> L("${minutes / 60} 小时后", "in ${minutes / 60} h")
        at.toLocalDate() == now.toLocalDate().plusDays(1) -> L("明天 ", "Tomorrow ") + at.format(com.lodo.app.ui.appFormatter("HH:mm"))
        else -> at.format(com.lodo.app.ui.appFormatter(L("M月d日 HH:mm", "MMM d HH:mm")))
    }
}

@Composable
private fun HealthGuide() {
    Text(L("在设置里打开「健康分析」后显示", "Turn on Health insights in Settings"), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/**
 * 活动圆环:三个同心的系统圆形进度条(不是 Canvas 自绘,同 iOS 用 Circle().trim)。
 * 超过 100% 的部分在同一圈上叠第二层深色;没数据的那圈只留轨道。
 */
@Composable
private fun ActivityRings(rings: List<com.lodo.app.core.OverviewCharts.Ring>, showLegend: Boolean) {
    val colors = listOf(androidx.compose.ui.graphics.Color(0xFFE5484D), androidx.compose.ui.graphics.Color(0xFF30A46C), androidx.compose.ui.graphics.Color(0xFF0090FF))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) {
            rings.forEachIndexed { i, r ->
                val size = 96.dp - (24 * i).dp
                val p = (r.progress ?: 0.0).toFloat()
                androidx.compose.material3.CircularProgressIndicator(progress = { p.coerceAtMost(1f) }, modifier = Modifier.size(size),
                    color = colors[i], trackColor = colors[i].copy(alpha = 0.18f), strokeWidth = 10.dp,
                    strokeCap = androidx.compose.ui.graphics.StrokeCap.Round)
                if (p > 1f) androidx.compose.material3.CircularProgressIndicator(progress = { (p - 1f).coerceAtMost(1f) }, modifier = Modifier.size(size),
                    color = colors[i].copy(red = colors[i].red * 0.7f, green = colors[i].green * 0.7f, blue = colors[i].blue * 0.7f),
                    trackColor = androidx.compose.ui.graphics.Color.Transparent, strokeWidth = 10.dp,
                    strokeCap = androidx.compose.ui.graphics.StrokeCap.Round)
            }
        }
        if (showLegend) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            rings.forEachIndexed { i, r ->
                val unit = when (r.kind) {
                    com.lodo.app.core.HealthMetricKind.ACTIVE_ENERGY -> L("千卡", "kcal")
                    com.lodo.app.core.HealthMetricKind.EXERCISE_MINUTES -> L("分钟", "min")
                    else -> L("步", "steps")
                }
                Text("${r.value?.toInt() ?: "–"} / ${r.goal.toInt()} $unit", color = colors[i], style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            }
        }
    }
}

/** 七根柱子,缺数据的那天留空(不补 0)。 */
@Composable
private fun NullableBars(values: List<Double?>, todayIndex: Int) {
    val max = (values.filterNotNull().maxOrNull() ?: 0.0).coerceAtLeast(1.0)
    Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
        values.forEachIndexed { i, v ->
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                if (v != null) Box(Modifier.fillMaxWidth().fillMaxHeight((v / max).toFloat().coerceAtLeast(0.06f))
                    .background(if (i == todayIndex) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                        RoundedCornerShape(6.dp)))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LayoutEditor(initial: List<OverviewEntry>, onSave: (List<OverviewEntry>) -> Unit, onDismiss: () -> Unit) {
    var list by remember { mutableStateOf(initial) }
    ModalBottomSheet(onDismissRequest = { onSave(list); onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("编辑总览", "Edit overview"), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { list = OverviewKind.decode("") }) { Text(L("恢复默认", "Reset")) }
                TextButton(onClick = { onSave(list); onDismiss() }) { Text(L("完成", "Done")) }
            }
            list.forEachIndexed { i, entry ->
                val kind = entry.kind
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Checkbox(checked = entry.visible, onCheckedChange = { c -> list = list.toMutableList().also { it[i] = entry.copy(visible = c) } })
                    Icon(kind.icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(kind.title, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // 尺寸:能切的给一颗「小/大」切换,不能切的只写着(同 iOS 拖角改尺寸的效果)。
                    if (kind.resizable) androidx.compose.material3.FilterChip(
                        selected = !entry.small,
                        onClick = { list = list.toMutableList().also { it[i] = entry.copy(small = !entry.small) } },
                        label = { Text(if (entry.small) L("小", "S") else L("大", "L")) },
                    ) else Text(if (entry.small) L("小", "S") else L("大", "L"), style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(horizontal = 12.dp))
                    IconButton(onClick = { if (i > 0) list = list.toMutableList().also { val t = it[i]; it[i] = it[i - 1]; it[i - 1] = t } }, enabled = i > 0) {
                        Icon(Icons.Filled.KeyboardArrowUp, L("上移", "Up"))
                    }
                    IconButton(onClick = { if (i < list.size - 1) list = list.toMutableList().also { val t = it[i]; it[i] = it[i + 1]; it[i + 1] = t } }, enabled = i < list.size - 1) {
                        Icon(Icons.Filled.KeyboardArrowDown, L("下移", "Down"))
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
