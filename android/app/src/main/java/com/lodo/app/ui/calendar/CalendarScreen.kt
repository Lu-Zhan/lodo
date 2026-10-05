package com.lodo.app.ui.calendar

import android.Manifest
import android.app.Application
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Today
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.RepeatType
import com.lodo.app.data.CalendarEvent
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.SegmentedTabs
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters

class CalendarViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp
    var events by mutableStateOf<List<CalendarEvent>>(emptyList())
        private set
    var loadedRange by mutableStateOf<Pair<LocalDate, LocalDate>?>(null)
        private set

    fun load(from: LocalDate, to: LocalDate) = viewModelScope.launch {
        events = app.calendar.events(from, to)
        loadedRange = from to to
    }

    fun hasPermission() = app.calendar.hasPermission()
    fun openIntent(e: CalendarEvent) = app.calendar.openIntent(e)

    fun enable() = viewModelScope.launch { app.settings.setCalendarEnabled(true) }
    fun setMode(mode: String) = viewModelScope.launch { app.settings.setCalendarViewMode(mode) }

    /** 「转为任务」:按日程的标题和时间新建一条任务(同 iOS CalendarSync.importEvent 的一半)。 */
    fun toTask(e: CalendarEvent) = viewModelScope.launch {
        app.repository.saveNew(ParsedTask(
            e.title, if (e.allDay) e.start.toLocalDate().atStartOfDay() else e.start, e.allDay,
            if (e.allDay) 0 else java.time.Duration.between(e.start, e.end).toMinutes().toInt().coerceIn(0, 1440),
            RepeatType.NONE, emptyList(), emptyList(),
        ))
    }
}

/**
 * 「日历」页,对应 iOS CalendarView:只显示系统日历(CalendarContract)里的日程,任务在任务页看。
 * 视图:所有(按天列表)/ 当日 / 本周 / 本月;点开日程交给系统日历 app(编辑删除都在那里确认),
 * 长按「转为任务」。没连接(开关关/没授权)时整页是「连接日历」引导。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CalendarScreen(vm: CalendarViewModel = viewModel()) {
    val settings = LocalSettings.current
    val context = LocalContext.current
    var granted by remember { mutableStateOf(vm.hasPermission()) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        if (ok) vm.enable()
    }
    val modes = listOf("agenda", "day", "week", "month")
    var mode by rememberSaveable { mutableStateOf(settings.calendarViewMode.takeIf { it in modes } ?: "agenda") }
    var anchor by rememberSaveable { mutableStateOf(LocalDate.now()) }
    var toTaskEvent by remember { mutableStateOf<CalendarEvent?>(null) }
    val connected = settings.calendarEnabled && granted

    val range = when (mode) {
        "agenda" -> LocalDate.now().minusDays(7) to LocalDate.now().plusDays(90)
        "day" -> anchor.with(DayOfWeek.MONDAY) to anchor.with(DayOfWeek.SUNDAY)
        "week" -> anchor.with(DayOfWeek.MONDAY) to anchor.with(DayOfWeek.SUNDAY)
        else -> YearMonth.from(anchor).atDay(1).with(DayOfWeek.MONDAY) to YearMonth.from(anchor).atEndOfMonth().with(TemporalAdjusters.nextOrSame(DayOfWeek.SUNDAY))
    }
    LaunchedEffect(connected, range) { if (connected) vm.load(range.first, range.second) }

    LodoPage(
        title = L("日历", "Calendar"),
        focus = AgentFocus(AgentPageFocus.CALENDAR),
        askPrompt = L("要安排点什么?", "Anything to schedule?"),
        actions = {
            if (connected) {
                IconButton(onClick = { anchor = LocalDate.now() }) { Icon(Icons.Outlined.Today, L("今天", "Today")) }
            }
        },
    ) { padding ->
        if (!connected) {
            FullEmpty(Icons.Outlined.CalendarMonth, L("连接日历", "Connect your calendar"),
                L("在这里看系统日历里的日程。lodo 只读不写,改动在系统日历里完成。", "See your calendar events here. Lodo only reads; edits happen in your calendar app."), padding) {
                Button(onClick = { if (granted) vm.enable() else launcher.launch(Manifest.permission.READ_CALENDAR) }) {
                    Text(L("连接日历", "Connect"))
                }
            }
            return@LodoPage
        }
        Column(Modifier.fillMaxSize().padding(padding)) {
            SegmentedTabs(listOf(L("所有", "All"), L("当日", "Day"), L("本周", "Week"), L("本月", "Month")), modes.indexOf(mode),
                { mode = modes[it]; vm.setMode(mode) })
            when (mode) {
                "agenda" -> Agenda(vm.events, onOpen = { context.startActivity(vm.openIntent(it)) }, onLong = { toTaskEvent = it })
                "day" -> {
                    WeekStrip(anchor) { anchor = it }
                    DayList(anchor, vm.events, { context.startActivity(vm.openIntent(it)) }, { toTaskEvent = it })
                }
                "week" -> {
                    Pager(anchor.with(DayOfWeek.MONDAY).format(com.lodo.app.ui.appFormatter(L("M月d日", "MMM d"))) + " – " +
                        anchor.with(DayOfWeek.SUNDAY).format(com.lodo.app.ui.appFormatter(L("M月d日", "MMM d"))),
                        { anchor = anchor.minusWeeks(1) }, { anchor = anchor.plusWeeks(1) })
                    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        (0..6).map { anchor.with(DayOfWeek.MONDAY).plusDays(it.toLong()) }.forEach { day ->
                            item("h$day") { DayHeader(day) }
                            val list = vm.events.filter { it.covers(day) }
                            if (list.isEmpty()) item("e$day") { Text(L("没有日程", "No events"), color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(start = 4.dp)) }
                            items(list, key = { "$day" + it.occurrenceKey }) { EventRow(it, { context.startActivity(vm.openIntent(it)) }, { toTaskEvent = it }) }
                        }
                    }
                }
                else -> {
                    Pager(YearMonth.from(anchor).format(com.lodo.app.ui.appFormatter(L("yyyy年M月", "MMMM yyyy"))),
                        { anchor = anchor.minusMonths(1) }, { anchor = anchor.plusMonths(1) })
                    MonthGrid(anchor, vm.events) { anchor = it }
                    DayList(anchor, vm.events, { context.startActivity(vm.openIntent(it)) }, { toTaskEvent = it })
                }
            }
        }
    }
    toTaskEvent?.let { e ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { toTaskEvent = null },
            title = { Text(L("转为任务?", "Turn into a task?")) },
            text = { Text(L("按「${e.title}」的时间新建一条任务,到点会提醒你。", "Creates a task for \"${e.title}\" at its time.")) },
            confirmButton = { TextButton(onClick = { vm.toTask(e); toTaskEvent = null }) { Text(L("转为任务", "Create task")) } },
            dismissButton = { TextButton(onClick = { toTaskEvent = null }) { Text(L("取消", "Cancel")) } },
        )
    }
}

@Composable
private fun Pager(title: String, onPrev: () -> Unit, onNext: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onPrev) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, L("上一页", "Previous")) }
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        IconButton(onClick = onNext) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, L("下一页", "Next")) }
    }
}

@Composable
private fun DayHeader(day: LocalDate) {
    val today = LocalDate.now()
    val fmt = com.lodo.app.ui.appFormatter(L("M月d日 EEEE", "EEEE, MMM d"))
    Text((if (day == today) L("今天 · ", "Today · ") else "") + day.format(fmt), style = MaterialTheme.typography.titleSmall,
        color = if (day == today) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 10.dp, bottom = 2.dp, start = 4.dp))
}

@Composable
private fun Agenda(events: List<CalendarEvent>, onOpen: (CalendarEvent) -> Unit, onLong: (CalendarEvent) -> Unit) {
    val today = LocalDate.now()
    val days = remember(events) {
        val set = sortedSetOf<LocalDate>()
        events.forEach { e ->
            var d = e.start.toLocalDate()
            var guard = 0
            while (e.covers(d) && guard++ < 60) { set += d; d = d.plusDays(1) }
        }
        set.toList()
    }
    val state = rememberLazyListState()
    LaunchedEffect(days) {
        val idx = days.indexOfFirst { !it.isBefore(today) }
        if (idx > 0) state.scrollToItem(idx * 2)
    }
    if (days.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(L("接下来没有日程", "No upcoming events"), color = MaterialTheme.colorScheme.outline) }
        return
    }
    LazyColumn(state = state, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        days.forEach { day ->
            item("h$day") { DayHeader(day) }
            item("l$day") {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    events.filter { it.covers(day) }.forEach { EventRow(it, { onOpen(it) }, { onLong(it) }) }
                }
            }
        }
    }
}

@Composable
private fun DayList(day: LocalDate, events: List<CalendarEvent>, onOpen: (CalendarEvent) -> Unit, onLong: (CalendarEvent) -> Unit) {
    val list = events.filter { it.covers(day) }.sortedWith(compareBy({ !it.allDay }, { it.start }))
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        item("h") { DayHeader(day) }
        if (list.isEmpty()) item("e") { Text(L("这一天没有日程", "No events this day"), color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(4.dp)) }
        items(list, key = { it.occurrenceKey }) { EventRow(it, { onOpen(it) }, { onLong(it) }) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EventRow(e: CalendarEvent, onOpen: () -> Unit, onLong: () -> Unit) {
    val timeFmt = com.lodo.app.ui.appFormatter("HH:mm")
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = onLong)) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(4.dp).height(36.dp).background(Color(e.color).copy(alpha = 1f), RoundedCornerShape(2.dp)))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(e.title.ifBlank { L("(无标题)", "(No title)") }, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                Text(
                    (if (e.allDay) L("全天", "All day") else e.start.format(timeFmt) + " – " + e.end.format(timeFmt)) +
                        (if (e.location.isNotBlank()) " · ${e.location}" else "") + " · " + e.calendarName,
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun WeekStrip(selected: LocalDate, onSelect: (LocalDate) -> Unit) {
    val monday = selected.with(DayOfWeek.MONDAY)
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { onSelect(selected.minusWeeks(1)) }) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, null) }
        (0..6).forEach { i ->
            val d = monday.plusDays(i.toLong())
            val sel = d == selected
            Column(Modifier.weight(1f).clickable { onSelect(d) }.padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(d.format(com.lodo.app.ui.appFormatter("E")), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Box(Modifier.size(34.dp).background(if (sel) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape), contentAlignment = Alignment.Center) {
                    Text("${d.dayOfMonth}", color = if (sel) MaterialTheme.colorScheme.onPrimary else if (d == LocalDate.now()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                }
            }
        }
        IconButton(onClick = { onSelect(selected.plusWeeks(1)) }) { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) }
    }
}

/** 月格:按周一起头(同 iOS CalendarWeek 的 0=周一口径),有日程的日子下面一个小点。 */
@Composable
private fun MonthGrid(anchor: LocalDate, events: List<CalendarEvent>, onSelect: (LocalDate) -> Unit) {
    val month = YearMonth.from(anchor)
    val first = month.atDay(1).with(DayOfWeek.MONDAY)
    val weeks = ((month.atEndOfMonth().with(TemporalAdjusters.nextOrSame(DayOfWeek.SUNDAY)).toEpochDay() - first.toEpochDay() + 1) / 7).toInt()
    Column(Modifier.padding(horizontal = 12.dp)) {
        Row { (0..6).forEach { i ->
            Text(first.plusDays(i.toLong()).format(com.lodo.app.ui.appFormatter("E")), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        } }
        repeat(weeks) { w ->
            Row {
                (0..6).forEach { i ->
                    val d = first.plusDays((w * 7 + i).toLong())
                    val inMonth = YearMonth.from(d) == month
                    val sel = d == anchor
                    val has = events.any { it.covers(d) }
                    Column(Modifier.weight(1f).aspectRatio(1.1f).clickable { onSelect(d) }, horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center) {
                        Box(Modifier.size(32.dp).background(if (sel) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape), contentAlignment = Alignment.Center) {
                            Text("${d.dayOfMonth}", color = when {
                                sel -> MaterialTheme.colorScheme.onPrimary
                                d == LocalDate.now() -> MaterialTheme.colorScheme.primary
                                inMonth -> MaterialTheme.colorScheme.onSurface
                                else -> MaterialTheme.colorScheme.outline
                            }, fontWeight = if (has) FontWeight.Bold else null)
                        }
                        Box(Modifier.size(5.dp).background(if (has && !sel) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape))
                    }
                }
            }
        }
    }
}
