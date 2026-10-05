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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.verticalScroll
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

    /** 「转为任务」:按日程的标题和时间新建一条任务;写开关开着时同时记进账本,从此双向(同 iOS CalendarSync.importEvent)。 */
    fun toTask(e: CalendarEvent) = viewModelScope.launch {
        val task = app.repository.saveNew(ParsedTask(
            e.title, if (e.allDay) e.start.toLocalDate().atStartOfDay() else e.start, e.allDay,
            if (e.allDay) 0 else java.time.Duration.between(e.start, e.end).toMinutes().toInt().coerceIn(0, 1440),
            RepeatType.NONE, emptyList(), emptyList(),
        ))
        app.calendarSync.claim(e, task.uuid)
    }

    fun hasWritePermission() = app.calendar.hasWritePermission()

    /** 删除用户的一条日程(用户在详情页里点的、确认过的);删完重新拉一遍。 */
    fun delete(e: CalendarEvent, onlyThis: Boolean, onDone: (Boolean) -> Unit) = viewModelScope.launch {
        val ok = app.calendar.delete(e, onlyThis)
        loadedRange?.let { (a, b) -> events = app.calendar.events(a, b) }
        onDone(ok)
    }
}

/**
 * 「日历」页,对应 iOS CalendarView:只显示系统日历(CalendarContract)里的日程,任务在任务页看。
 * 视图:所有(按天列表)/ 当日 / 三日 / 本周(时间轴)/ 本月 / 全年;点开日程弹应用内详情
 * (删除在这里确认,编辑交给系统日历 app),长按「转为任务」。没连接(开关关/没授权)时整页是「连接日历」引导。
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
    val modes = listOf("agenda", "day", "three", "week", "month", "year")
    var mode by rememberSaveable { mutableStateOf(settings.calendarViewMode.takeIf { it in modes } ?: "agenda") }
    var anchor by rememberSaveable { mutableStateOf(LocalDate.now()) }
    var toTaskEvent by remember { mutableStateOf<CalendarEvent?>(null) }
    var detail by remember { mutableStateOf<CalendarEvent?>(null) }
    val connected = settings.calendarEnabled && granted

    val range = when (mode) {
        "agenda" -> LocalDate.now().minusDays(7) to LocalDate.now().plusDays(90)
        "day" -> anchor.with(DayOfWeek.MONDAY) to anchor.with(DayOfWeek.SUNDAY)
        "three" -> anchor to anchor.plusDays(2)
        "week" -> anchor.with(DayOfWeek.MONDAY) to anchor.with(DayOfWeek.SUNDAY)
        "year" -> anchor.withDayOfYear(1) to anchor.withDayOfYear(anchor.lengthOfYear())
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
                L("在这里看系统日历里的日程。想让任务也出现在日历里,到设置里打开「任务写入日历」。", "See your calendar events here. To put tasks on your calendar too, turn on \"Sync tasks to calendar\" in Settings."), padding) {
                Button(onClick = { if (granted) vm.enable() else launcher.launch(Manifest.permission.READ_CALENDAR) }) {
                    Text(L("连接日历", "Connect"))
                }
            }
            return@LodoPage
        }
        Column(Modifier.fillMaxSize().padding(padding)) {
            ModeMenuRow(mode, modes) { mode = it; vm.setMode(it) }
            val open: (CalendarEvent) -> Unit = { detail = it }
            val long: (CalendarEvent) -> Unit = { toTaskEvent = it }
            val md = com.lodo.app.ui.appFormatter(L("M月d日", "MMM d"))
            when (mode) {
                "agenda" -> Agenda(vm.events, onOpen = open, onLong = long)
                "day" -> {
                    WeekStrip(anchor) { anchor = it }
                    Timeline(listOf(anchor), vm.events, open, long, showHeader = false)
                }
                "three" -> {
                    Pager(anchor.format(md) + " – " + anchor.plusDays(2).format(md), { anchor = anchor.minusDays(3) }, { anchor = anchor.plusDays(3) })
                    Timeline((0..2).map { anchor.plusDays(it.toLong()) }, vm.events, open, long)
                }
                "week" -> {
                    val monday = anchor.with(DayOfWeek.MONDAY)
                    Pager(monday.format(md) + " – " + monday.plusDays(6).format(md), { anchor = anchor.minusWeeks(1) }, { anchor = anchor.plusWeeks(1) })
                    Timeline((0..6).map { monday.plusDays(it.toLong()) }, vm.events, open, long)
                }
                "month" -> {
                    Pager(YearMonth.from(anchor).format(com.lodo.app.ui.appFormatter(L("yyyy年M月", "MMMM yyyy"))),
                        { anchor = anchor.minusMonths(1) }, { anchor = anchor.plusMonths(1) })
                    // 再点一次已选中的那天进当日(同 iOS)。
                    MonthGrid(anchor, vm.events) { d -> if (d == anchor) { mode = "day"; vm.setMode("day") } else anchor = d }
                    DayList(anchor, vm.events, open, long)
                }
                else -> {
                    Pager(L("${anchor.year} 年", "${anchor.year}"), { anchor = anchor.minusYears(1) }, { anchor = anchor.plusYears(1) })
                    YearGrid(anchor.year, vm.events) { m -> anchor = m.atDay(1); mode = "month"; vm.setMode("month") }
                }
            }
        }
    }
    detail?.let { e ->
        EventSheet(e, vm, onDismiss = { detail = null },
            onOpenInCalendar = { runCatching { context.startActivity(vm.openIntent(e)) } },
            onToTask = { detail = null; toTaskEvent = e })
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

/** 视图切换:六档放不进分段按钮,换成一排可横滑的选择胶囊。 */
@Composable
private fun ModeMenuRow(mode: String, modes: List<String>, onSelect: (String) -> Unit) {
    val labels = mapOf(
        "agenda" to L("所有", "All"), "day" to L("当日", "Day"), "three" to L("三日", "3 Days"),
        "week" to L("本周", "Week"), "month" to L("本月", "Month"), "year" to L("全年", "Year"),
    )
    androidx.compose.foundation.lazy.LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(modes) { m ->
            androidx.compose.material3.FilterChip(selected = m == mode, onClick = { onSelect(m) }, label = { Text(labels[m] ?: m) })
        }
    }
}

private val HourHeight = 52.dp

/**
 * 时间轴(当日/三日/本周,同 iOS CalendarTimelineView):顶部全天行 + 24 小时网格,重叠的日程按
 * `CalendarLayout.columns` 分列。块是圆角矩形 + offset 摆出来的,不是 Canvas 自绘。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Timeline(
    days: List<LocalDate>, events: List<CalendarEvent>,
    onOpen: (CalendarEvent) -> Unit, onLong: (CalendarEvent) -> Unit, showHeader: Boolean = true,
) {
    val today = LocalDate.now()
    val gutter = 44.dp
    val scroll = androidx.compose.foundation.rememberScrollState()
    val density = androidx.compose.ui.platform.LocalDensity.current
    LaunchedEffect(Unit) {
        val hour = if (days.contains(today)) maxOf(0, java.time.LocalTime.now().hour - 1) else 8
        scroll.scrollTo(with(density) { (HourHeight * hour).roundToPx() })
    }
    Column(Modifier.fillMaxSize()) {
        if (showHeader) Row(Modifier.fillMaxWidth().padding(start = gutter, end = 8.dp)) {
            days.forEach { d ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(d.format(com.lodo.app.ui.appFormatter("E")), style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Box(Modifier.size(28.dp).background(if (d == today) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape),
                        contentAlignment = Alignment.Center) {
                        Text("${d.dayOfMonth}", style = MaterialTheme.typography.bodyMedium,
                            color = if (d == today) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface)
                    }
                }
            }
        }
        // 全天行
        val allDay = days.map { d -> events.filter { it.allDay && it.covers(d) } }
        if (allDay.any { it.isNotEmpty() }) {
            Row(Modifier.fillMaxWidth().padding(start = gutter, end = 8.dp, top = 4.dp, bottom = 4.dp)) {
                allDay.forEach { list ->
                    Column(Modifier.weight(1f).padding(horizontal = 1.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        list.forEach { e ->
                            Surface(color = Color(e.color).copy(alpha = 0.22f), shape = RoundedCornerShape(6.dp),
                                modifier = Modifier.fillMaxWidth().combinedClickable(onClick = { onOpen(e) }, onLongClick = { onLong(e) })) {
                                Text(e.title.ifBlank { L("(无标题)", "(No title)") }, style = MaterialTheme.typography.labelSmall, maxLines = 1,
                                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
                            }
                        }
                    }
                }
            }
        }
        androidx.compose.material3.HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Box(Modifier.fillMaxWidth().weight(1f).verticalScroll(scroll)) {
            Box(Modifier.fillMaxWidth().height(HourHeight * 24)) {
                // 小时线与刻度
                (0..23).forEach { h ->
                    Row(Modifier.offset(y = HourHeight * h).fillMaxWidth(), verticalAlignment = Alignment.Top) {
                        Text(if (h == 0) "" else "%02d:00".format(h), style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.outline, modifier = Modifier.width(gutter).offset(y = (-7).dp).padding(start = 6.dp))
                        Box(Modifier.weight(1f).height(1.dp).background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)))
                    }
                }
                Row(Modifier.fillMaxSize().padding(start = gutter, end = 8.dp)) {
                    days.forEach { d ->
                        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.weight(1f).fillMaxSize().padding(horizontal = 1.dp)) {
                            val timed = events.filter { !it.allDay && it.covers(d) }
                            val spans = timed.map { e ->
                                val s = if (e.start.toLocalDate().isBefore(d)) 0 else e.start.hour * 60 + e.start.minute
                                val en = if (e.end.toLocalDate().isAfter(d)) 24 * 60 else e.end.hour * 60 + e.end.minute
                                s to maxOf(en, s)
                            }
                            val slots = com.lodo.app.core.CalendarLayout.columns(spans)
                            val colWidth = maxWidth
                            slots.forEach { slot ->
                                val e = timed[slot.index]
                                val (s, en) = spans[slot.index]
                                val w = colWidth / slot.columns
                                Surface(
                                    color = Color(e.color).copy(alpha = 0.22f), shape = RoundedCornerShape(6.dp),
                                    modifier = Modifier
                                        .offset(x = w * slot.column, y = HourHeight * (s / 60f))
                                        .width(w - 2.dp).height(maxOf(HourHeight * ((en - s) / 60f), 18.dp))
                                        .combinedClickable(onClick = { onOpen(e) }, onLongClick = { onLong(e) }),
                                ) {
                                    Row {
                                        Box(Modifier.width(3.dp).fillMaxSize().background(Color(e.color)))
                                        Text(e.title.ifBlank { L("(无标题)", "(No title)") }, style = MaterialTheme.typography.labelSmall,
                                            maxLines = 3, modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp))
                                    }
                                }
                            }
                            if (d == today) {
                                val now = java.time.LocalTime.now()
                                Box(Modifier.offset(y = HourHeight * ((now.hour * 60 + now.minute) / 60f)).fillMaxWidth().height(2.dp)
                                    .background(com.lodo.app.ui.theme.LodoColor.critical))
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 全年:12 个小月历,不画日程,有日程的日子数字加粗;点月份进本月(同 iOS)。 */
@Composable
private fun YearGrid(year: Int, events: List<CalendarEvent>, onMonth: (YearMonth) -> Unit) {
    val busy = remember(events) {
        buildSet { events.forEach { e -> var d = e.start.toLocalDate(); var g = 0; while (e.covers(d) && g++ < 60) { add(d); d = d.plusDays(1) } } }
    }
    LazyColumn(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
        items((1..12).chunked(3)) { row ->
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                row.forEach { m ->
                    val ym = YearMonth.of(year, m)
                    Column(Modifier.weight(1f).clickable { onMonth(ym) }.padding(4.dp)) {
                        Text(ym.format(com.lodo.app.ui.appFormatter(L("M月", "MMM"))), style = MaterialTheme.typography.titleSmall,
                            color = if (ym == YearMonth.now()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(bottom = 4.dp))
                        val first = ym.atDay(1).with(DayOfWeek.MONDAY)
                        repeat(6) { w ->
                            Row {
                                (0..6).forEach { i ->
                                    val d = first.plusDays((w * 7 + i).toLong())
                                    Text(if (YearMonth.from(d) == ym) "${d.dayOfMonth}" else "",
                                        style = MaterialTheme.typography.labelSmall.copy(fontSize = androidx.compose.ui.unit.TextUnit(9f, androidx.compose.ui.unit.TextUnitType.Sp)),
                                        fontWeight = if (d in busy) FontWeight.Bold else null,
                                        color = when {
                                            d == LocalDate.now() -> MaterialTheme.colorScheme.primary
                                            d in busy -> MaterialTheme.colorScheme.onSurface
                                            else -> MaterialTheme.colorScheme.onSurfaceVariant
                                        },
                                        textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.weight(1f))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * 日程详情(对应 iOS 点开日程弹的系统详情页):看详情、「在日历中编辑」交给系统日历 app、
 * 「转为任务」、删除(重复日程问这一次/所有)。删除是用户在这里亲手点并确认的,lodo 不会自己删人家的日程。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun EventSheet(e: CalendarEvent, vm: CalendarViewModel, onDismiss: () -> Unit, onOpenInCalendar: () -> Unit, onToTask: () -> Unit) {
    var confirm by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val writeLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok -> if (ok) confirm = true }
    val fmt = com.lodo.app.ui.appFormatter(L("M月d日 EEEE HH:mm", "EEE, MMM d HH:mm"))
    val dayFmt = com.lodo.app.ui.appFormatter(L("M月d日 EEEE", "EEE, MMM d"))
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(12.dp).background(Color(e.color), CircleShape))
                Spacer(Modifier.width(10.dp))
                Text(e.title.ifBlank { L("(无标题)", "(No title)") }, style = MaterialTheme.typography.titleLarge)
            }
            Text(
                if (e.allDay) {
                    val last = e.end.toLocalDate().minusDays(1)
                    e.start.format(dayFmt) + (if (last.isAfter(e.start.toLocalDate())) " – " + last.format(dayFmt) else "") + " · " + L("全天", "All day")
                } else e.start.format(fmt) + " – " + e.end.format(if (e.end.toLocalDate() == e.start.toLocalDate()) com.lodo.app.ui.appFormatter("HH:mm") else fmt),
                style = MaterialTheme.typography.bodyLarge,
            )
            if (e.rrule.isNotBlank()) Text(L("重复日程", "Repeating event"), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (e.location.isNotBlank()) Text(e.location, style = MaterialTheme.typography.bodyMedium)
            Text(L("日历:", "Calendar: ") + e.calendarName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (e.description.isNotBlank()) Text(e.description, style = MaterialTheme.typography.bodyMedium)
            message?.let { Text(it, color = com.lodo.app.ui.theme.LodoColor.critical, style = MaterialTheme.typography.bodySmall) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                androidx.compose.material3.FilledTonalButton(onClick = onOpenInCalendar) { Text(L("在日历中编辑", "Edit in Calendar")) }
                androidx.compose.material3.OutlinedButton(onClick = onToTask) { Text(L("转为任务", "Make task")) }
            }
            TextButton(onClick = { if (vm.hasWritePermission()) confirm = true else writeLauncher.launch(Manifest.permission.WRITE_CALENDAR) }) {
                Text(L("删除日程", "Delete event"), color = com.lodo.app.ui.theme.LodoColor.critical)
            }
        }
    }
    if (confirm) {
        val repeating = e.rrule.isNotBlank()
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text(L("删除这条日程?", "Delete this event?")) },
            text = { Text(if (repeating) L("这是重复日程。", "This is a repeating event.") else L("会从系统日历里删掉,不能撤销。", "It will be removed from your calendar.")) },
            confirmButton = {
                Row {
                    if (repeating) TextButton(onClick = {
                        confirm = false
                        vm.delete(e, onlyThis = false) { ok -> if (ok) onDismiss() else message = L("删除失败(这本日历可能是只读的)", "Couldn't delete (read-only calendar?)") }
                    }) { Text(L("所有", "All"), color = com.lodo.app.ui.theme.LodoColor.critical) }
                    TextButton(onClick = {
                        confirm = false
                        vm.delete(e, onlyThis = true) { ok -> if (ok) onDismiss() else message = L("删除失败(这本日历可能是只读的)", "Couldn't delete (read-only calendar?)") }
                    }) { Text(if (repeating) L("仅这一次", "This one") else L("删除", "Delete"), color = com.lodo.app.ui.theme.LodoColor.critical) }
                }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(L("取消", "Cancel")) } },
        )
    }
}
