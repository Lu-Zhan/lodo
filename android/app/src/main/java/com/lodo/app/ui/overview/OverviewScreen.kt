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
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/** 总览模块种类,存储值别改(同 iOS OverviewWidgetKind 的思路)。small = 半宽。 */
enum class OverviewKind(val raw: String, val small: Boolean, val icon: ImageVector) {
    NOW("now", true, Icons.Outlined.Schedule),
    WEEK("week", true, Icons.Outlined.ShowChart),
    DUE("due", false, Icons.Outlined.NotificationsActive),
    TODAY_TASKS("todayTasks", false, Icons.Outlined.Checklist),
    EVENTS("events", false, Icons.Outlined.CalendarMonth),
    COUNTDOWN("countdown", true, Icons.Outlined.HourglassTop),
    COUNT_UP("countUp", true, Icons.Outlined.Update),
    SUGGESTION("suggestion", false, Icons.Filled.AutoAwesome),
    MEMORIES("memories", false, Icons.Outlined.Bookmarks),
    HEALTH("health", false, Icons.Outlined.FavoriteBorder);

    val title get() = when (this) {
        NOW -> L("此刻", "Now")
        WEEK -> L("本周完成", "This week")
        DUE -> L("已到期提醒", "Due now")
        TODAY_TASKS -> L("今天任务", "Today")
        EVENTS -> L("今日日程", "Events today")
        COUNTDOWN -> L("倒数日", "Countdown")
        COUNT_UP -> L("正数日", "Counting up")
        SUGGESTION -> L("处理建议", "Suggestion")
        MEMORIES -> L("今天的记忆", "Today's memories")
        HEALTH -> L("健康", "Health")
    }

    companion object {
        /** 布局容错:认不出的丢、重复的留第一个、老布局里没有的新种类补在末尾(同 iOS OverviewLayout)。 */
        fun decode(raw: String): List<Pair<OverviewKind, Boolean>> {
            val parsed = raw.split(",").mapNotNull { part ->
                val (k, v) = part.split(":").let { it.getOrNull(0) to it.getOrNull(1) }
                entries.firstOrNull { it.raw == k }?.let { it to (v != "0") }
            }.distinctBy { it.first }
            return parsed + entries.filter { k -> parsed.none { it.first == k } }.map { it to true }
        }

        fun encode(list: List<Pair<OverviewKind, Boolean>>) = list.joinToString(",") { "${it.first.raw}:${if (it.second) 1 else 0}" }
    }
}

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

    fun loadEvents() = viewModelScope.launch {
        if (app.settings.snapshot().calendarEnabled) events = app.calendar.events(LocalDate.now(), LocalDate.now())
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

    fun saveLayout(list: List<Pair<OverviewKind, Boolean>>) = viewModelScope.launch { app.settings.setOverviewLayout(OverviewKind.encode(list)) }
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
    LaunchedEffect(Unit) { vm.loadEvents() }
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
        val visible = layout.filter { it.second }.map { it.first }.filter { k ->
            when (k) {
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
            items(visible, key = { it.raw }, span = { GridItemSpan(if (it.small) 1 else minOf(2, maxLineSpan)) }) { kind ->
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
                        Widget(kind, small = true) {
                            Text(L("${counts.sum()} 件", "${counts.sum()} done"), fontSize = 28.sp, fontWeight = FontWeight.Bold)
                            Bars(counts, today.dayOfWeek.value - 1)
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
                        Widget(kind, small = true, onClick = { shell.go(AppSection.COUNTDOWN) }) {
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
                        Widget(kind, small = true, onClick = { shell.go(AppSection.COUNTDOWN) }) {
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LayoutEditor(initial: List<Pair<OverviewKind, Boolean>>, onSave: (List<Pair<OverviewKind, Boolean>>) -> Unit, onDismiss: () -> Unit) {
    var list by remember { mutableStateOf(initial) }
    ModalBottomSheet(onDismissRequest = { onSave(list); onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("编辑总览", "Edit overview"), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { list = OverviewKind.decode("") }) { Text(L("恢复默认", "Reset")) }
                TextButton(onClick = { onSave(list); onDismiss() }) { Text(L("完成", "Done")) }
            }
            list.forEachIndexed { i, (kind, on) ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                    Checkbox(checked = on, onCheckedChange = { c -> list = list.toMutableList().also { it[i] = kind to c } })
                    Icon(kind.icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(kind.title + if (kind.small) L(" · 小", " · small") else "", modifier = Modifier.weight(1f))
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
