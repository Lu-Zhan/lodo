package com.lodo.app.ui.countdown

import android.app.Application
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
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
import com.lodo.app.core.CountdownEntry
import com.lodo.app.core.CountdownPlan
import com.lodo.app.core.CountdownSpan
import com.lodo.app.data.CountdownEntity
import com.lodo.app.data.entry
import com.lodo.app.data.joinIntCsv
import com.lodo.app.data.offsetLabel
import com.lodo.app.data.toEpochMillis
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.ui.DateTimeField
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter

class CountdownViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp
    val items = app.countdowns.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    var insight by mutableStateOf<String?>(null)
        private set

    fun save(e: CountdownEntity) = viewModelScope.launch { app.countdowns.save(e) }
    fun delete(uuid: String) = viewModelScope.launch { app.countdowns.delete(uuid) }
    fun archive(uuid: String, archived: Boolean) = viewModelScope.launch { app.countdowns.setArchived(uuid, archived) }

    /** 顶部那一句:按"当天 + 素材 + 语言"缓存,日子或内容变了才重新要;没配 AI、失败都不显示。 */
    fun loadInsight(entries: List<CountdownEntry>) = viewModelScope.launch {
        if (entries.none { !it.archived }) { insight = null; return@launch }
        val summary = CountdownPlan.promptSummary(entries, LocalDateTime.now())
        val key = LocalDate.now().toString() + summary.hashCode() + DeepSeekClient.languageName()
        val prefs = app.getSharedPreferences("countdown-insight", 0)
        if (prefs.getString("key", null) == key) { insight = prefs.getString("text", null); return@launch }
        val config = app.settings.aiConfig()
        if (config.apiKey.isNullOrBlank()) return@launch
        runCatching { DeepSeekClient.countdownInsight(config, summary) }.getOrNull()?.let {
            prefs.edit().putString("key", key).putString("text", it).apply()
            insight = it
        }
    }
}

/** 倒数日的展示文案:主数字 + 说明(同 iOS CountdownText)。 */
fun countdownSpanText(span: CountdownSpan, precise: Boolean = true): Pair<String, String> {
    val minutes = span.minutes
    if (precise && minutes != null) {
        val text = if (minutes >= 60) L("${minutes / 60} 小时", "${minutes / 60} h") else L("$minutes 分钟", "$minutes min")
        return text to when (span.milestone) {
            CountdownSpan.Milestone.UNTIL_START -> L("后开始", "to start")
            CountdownSpan.Milestone.SINCE_START -> L("前开始", "since start")
            CountdownSpan.Milestone.UNTIL_END -> L("后结束", "to end")
            CountdownSpan.Milestone.SINCE_END -> L("前结束", "since end")
        }
    }
    if (span.days == 0) return L("今天", "Today") to when (span.milestone) {
        CountdownSpan.Milestone.UNTIL_START, CountdownSpan.Milestone.SINCE_START -> L("就是今天", "is today")
        CountdownSpan.Milestone.UNTIL_END -> L("今天结束", "ends today")
        CountdownSpan.Milestone.SINCE_END -> L("今天结束", "ended today")
    }
    val n = L("${span.days} 天", "${span.days} d")
    return n to when (span.milestone) {
        CountdownSpan.Milestone.UNTIL_START -> L("还有", "until start")
        CountdownSpan.Milestone.SINCE_START -> L("已经", "since")
        CountdownSpan.Milestone.UNTIL_END -> L("还有·结束", "until end")
        CountdownSpan.Milestone.SINCE_END -> L("已结束", "since end")
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun CountdownScreen(vm: CountdownViewModel = viewModel()) {
    val items by vm.items.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<CountdownEntity?>(null) }
    var creating by remember { mutableStateOf(false) }
    var showArchived by rememberSaveable { mutableStateOf(false) }
    val now = remember(items) { LocalDateTime.now() }
    val entries = items.map { it.entry() }
    LaunchedEffect(items) { vm.loadInsight(entries) }
    val active = entries.filter { !it.archived }
    val upcoming = CountdownPlan.sorted(active.filter { !CountdownPlan.isPast(it, now) }, now)
    val countUps = CountdownPlan.countUps(active, now)
    val archived = entries.filter { it.archived }
    val byId = items.associateBy { it.uuid }

    LodoPage(
        title = L("倒数", "Countdown"),
        focus = AgentFocus(AgentPageFocus.COUNTDOWN),
        askPrompt = L("有什么日子要记?", "Any date to count down to?"),
        actions = { IconButton(onClick = { creating = true }) { Icon(Icons.Filled.Add, L("新建倒数日", "New countdown")) } },
    ) { padding ->
        if (items.isEmpty()) {
            FullEmpty(Icons.Outlined.HourglassTop, L("还没有倒数日", "No countdowns yet"),
                L("考试、搬家、演唱会、纪念日……说一句「记一下 12 月 20 号考研」就行", "Exams, moves, anniversaries — just tell the AI."), padding)
            return@LodoPage
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            vm.insight?.let { text ->
                item("insight") {
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
                        shape = RoundedCornerShape(24.dp)) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.AutoAwesome, null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.size(10.dp))
                            Text(text, color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            }
            if (upcoming.isNotEmpty()) {
                item("h1") { Header(L("倒数日", "Upcoming")) }
                items(upcoming, key = { it.id }) { e ->
                    CountdownCard(e, now, MaterialTheme.colorScheme.primary, onClick = { editing = byId[e.id] },
                        onArchive = { vm.archive(e.id, true) }, onDelete = { vm.delete(e.id) })
                }
            }
            if (countUps.isNotEmpty()) {
                item("h2") { Header(L("正数日", "Counting up")) }
                items(countUps, key = { it.entry.id }) { c ->
                    CountdownCard(c.entry, now, LodoColor.positive, next = c.next, onClick = { editing = byId[c.entry.id] },
                        onArchive = { vm.archive(c.entry.id, true) }, onDelete = { vm.delete(c.entry.id) })
                }
            }
            if (archived.isNotEmpty()) {
                item("h3") {
                    TextButton(onClick = { showArchived = !showArchived }) {
                        Text(L("已归档(${archived.size})", "Archived (${archived.size})"))
                        Icon(if (showArchived) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null)
                    }
                }
                if (showArchived) items(archived, key = { "a" + it.id }) { e ->
                    CountdownCard(e, now, MaterialTheme.colorScheme.outline, onClick = { editing = byId[e.id] },
                        onArchive = { vm.archive(e.id, false) }, onDelete = { vm.delete(e.id) }, archived = true)
                }
            }
        }
    }
    if (creating || editing != null) {
        CountdownEditSheet(
            existing = editing, widgetCount = items.count { it.showInWidget && !it.archived && it.uuid != editing?.uuid },
            onSave = { vm.save(it); creating = false; editing = null },
            onDelete = { editing?.let { vm.delete(it.uuid) }; editing = null },
            onDismiss = { creating = false; editing = null },
        )
    }
}

@Composable
private fun Header(text: String) =
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp, start = 4.dp))

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CountdownCard(
    e: CountdownEntry, now: LocalDateTime, accent: Color, next: CountdownPlan.Milestone? = null,
    onClick: () -> Unit, onArchive: () -> Unit, onDelete: () -> Unit, archived: Boolean = false,
) {
    var menu by remember { mutableStateOf(false) }
    val span = CountdownPlan.primary(e, now)
    val (number, label) = countdownSpanText(span)
    val fmt = DateTimeFormatter.ofPattern(if (e.allDay) L("yyyy年M月d日 E", "EEE, MMM d, yyyy") else L("yyyy年M月d日 E HH:mm", "EEE, MMM d, yyyy HH:mm"))
    Card(
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = { menu = true }),
    ) {
        Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(e.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(e.start.format(fmt) + (e.end?.let { " – " + it.format(fmt) } ?: ""),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                next?.let { m ->
                    val whenText = if (m.daysAway == 0) L("今天", "Today") else L("${m.daysAway} 天后", "in ${m.daysAway} d")
                    val what = when (val k = m.kind) {
                        is CountdownPlan.MilestoneKind.Anniversary -> L("满 ${k.years} 周年", "${k.years}-year anniversary")
                        is CountdownPlan.MilestoneKind.DayCount -> L("满 ${k.days} 天", "${k.days} days")
                        else -> ""
                    }
                    Text("$whenText $what", style = MaterialTheme.typography.labelLarge, color = accent)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(number, fontSize = 30.sp, fontWeight = FontWeight.Bold, color = accent)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(if (archived) L("取消归档", "Unarchive") else L("归档", "Archive")) }, onClick = { menu = false; onArchive() })
            DropdownMenuItem(text = { Text(L("删除", "Delete"), color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun CountdownEditSheet(
    existing: CountdownEntity?, widgetCount: Int,
    onSave: (CountdownEntity) -> Unit, onDelete: () -> Unit, onDismiss: () -> Unit,
) {
    var title by remember { mutableStateOf(existing?.title ?: "") }
    var allDay by remember { mutableStateOf(existing?.allDay ?: true) }
    var start by remember { mutableStateOf(existing?.startMillis?.toLocalDateTime() ?: LocalDate.now().plusDays(7).atTime(LocalTime.of(9, 0))) }
    var hasEnd by remember { mutableStateOf(existing?.endMillis != null) }
    var end by remember { mutableStateOf(existing?.endMillis?.toLocalDateTime() ?: start.plusDays(1)) }
    var startReminders by remember { mutableStateOf(existing?.startReminderList?.toSet() ?: emptySet()) }
    var endReminders by remember { mutableStateOf(existing?.endReminderList?.toSet() ?: emptySet()) }
    var widget by remember { mutableStateOf(existing?.showInWidget ?: false) }
    var archived by remember { mutableStateOf(existing?.archived ?: false) }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp).animateContentSize(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text(L("取消", "Cancel")) }
                Text(if (existing == null) L("新建倒数日", "New countdown") else L("编辑倒数日", "Edit countdown"),
                    style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton(enabled = title.isNotBlank(), onClick = {
                    val s = if (allDay) start.toLocalDate().atStartOfDay() else start
                    val e = if (!hasEnd) null else if (allDay) end.toLocalDate().atStartOfDay() else end
                    onSave((existing ?: CountdownEntity(title = title, startMillis = 0)).copy(
                        title = title.trim(), startMillis = s.toEpochMillis(), endMillis = e?.takeIf { !it.isBefore(s) }?.toEpochMillis(),
                        allDay = allDay, startReminders = joinIntCsv(startReminders.sorted()),
                        endReminders = if (hasEnd) joinIntCsv(endReminders.sorted()) else "",
                        showInWidget = widget, archived = archived, notes = notes,
                    ))
                }) { Text(L("保存", "Save")) }
            }
            OutlinedTextField(title, { title = it }, label = { Text(L("名称", "Title")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            SwitchRow(L("全天", "All day"), allDay) { allDay = it }
            DateTimeField(L("开始", "Starts"), start, !allDay, { start = it })
            SwitchRow(L("有结束时间", "Has an end"), hasEnd) { hasEnd = it }
            if (hasEnd) DateTimeField(L("结束", "Ends"), end, !allDay, { end = it })
            Text(L("开始前提醒", "Remind before start"), style = MaterialTheme.typography.titleSmall)
            ReminderChips(startReminders) { startReminders = it }
            if (hasEnd) {
                Text(L("结束前提醒", "Remind before end"), style = MaterialTheme.typography.titleSmall)
                ReminderChips(endReminders) { endReminders = it }
            }
            SwitchRow(L("显示在桌面小组件(最多 3 件)", "Show in widget (max 3)"), widget, enabled = widget || widgetCount < CountdownPlan.WIDGET_LIMIT) { widget = it }
            SwitchRow(L("归档", "Archived"), archived) { archived = it }
            OutlinedTextField(notes, { notes = it }, label = { Text(L("备注", "Notes")) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            if (existing != null) TextButton(onClick = onDelete) { Text(L("删除倒数日", "Delete countdown"), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ReminderChips(selected: Set<Int>, onChange: (Set<Int>) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CountdownPlan.reminderPresets.forEach { m ->
            FilterChip(selected = m in selected, onClick = { onChange(if (m in selected) selected - m else selected + m) },
                label = { Text(if (m == 0) L("准时", "On time") else offsetLabel(m)) })
        }
    }
}

@Composable
fun SwitchRow(label: String, checked: Boolean, enabled: Boolean = true, subtitle: String? = null, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}
