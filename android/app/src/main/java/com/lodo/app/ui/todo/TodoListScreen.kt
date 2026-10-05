package com.lodo.app.ui.todo

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.EditCalendar
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.foundation.combinedClickable
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lodo.app.LodoApp
import com.lodo.app.PendingRoute
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.RepeatType
import com.lodo.app.ui.localizedDateTimeLabel
import com.lodo.app.ui.localizedWeekdayList
import com.lodo.app.ui.localizedWeekdayLabels
import com.lodo.app.data.TaskEntity
import com.lodo.app.notify.NotificationPermission
import com.lodo.app.ui.EmptyState
import com.lodo.app.ui.SectionHeader
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/** 任务页的四档筛选(同 iOS 任务页顶部「今天/未来/全部/已完成」)。 */
enum class TaskFilter { TODAY, FUTURE, ALL, DONE }

/**
 * 「任务」页,对应 iOS TodoListView:顶部四档筛选、置顶的「重要的事」、到期提醒卡
 * (完成/稍等/忽略 + 改期)、按日期分组的任务;新建一律走底部「问问 AI」(页面上没有「+」)。
 * 行:右滑完成、左滑删除,长按置顶/编辑。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun TodoListScreen(
    modifier: Modifier = Modifier,
    vm: TodoViewModel = viewModel(),
) {
    val state by vm.uiState.collectAsStateWithLifecycle()
    val app = LocalContext.current.applicationContext as LodoApp
    var filter by rememberSaveable { mutableStateOf(TaskFilter.TODAY) }

    val pendingRoute by app.pendingRoute.collectAsStateWithLifecycle()
    LaunchedEffect(pendingRoute) {
        (pendingRoute as? PendingRoute.Reschedule)?.let {
            vm.handleReschedule(it.uuid)
            app.pendingRoute.value = null
        }
    }

    val today = LocalDate.now()
    val dueUuids = state.due.map { it.uuid }.toSet()
    val pinned = state.pending.filter { it.pinned }.sortedByDescending { it.pinnedAtMillis ?: 0 }
    val upcoming = state.pending.filter { it.uuid !in dueUuids && !it.pinned }
    val listed = when (filter) {
        TaskFilter.TODAY -> upcoming.filter { !it.nextRemindAt.toLocalDate().isAfter(today) }
        TaskFilter.FUTURE -> upcoming.filter { it.nextRemindAt.toLocalDate().isAfter(today) }
        TaskFilter.ALL -> upcoming
        TaskFilter.DONE -> emptyList()
    }
    val groups = listed.groupBy { it.nextRemindAt.toLocalDate() }.toSortedMap().toList()

    com.lodo.app.ui.LodoPage(
        title = com.lodo.app.ui.L("任务", "Tasks"),
        focus = com.lodo.app.ai.AgentFocus(com.lodo.app.ai.AgentPageFocus.TODO),
        askPrompt = com.lodo.app.ui.L("要做点什么?", "What needs doing?"),
        modifier = modifier,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            com.lodo.app.ui.SegmentedTabs(
                labels = listOf(
                    com.lodo.app.ui.L("今天", "Today"), com.lodo.app.ui.L("未来", "Upcoming"),
                    com.lodo.app.ui.L("全部", "All"), com.lodo.app.ui.L("已完成", "Done"),
                ),
                selected = filter.ordinal,
                onSelect = { filter = TaskFilter.entries[it] },
            )
            if (filter == TaskFilter.DONE) {
                DoneListScreen(vm = vm)
                return@Column
            }
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            ) {
                if (state.notificationPermissionDenied) {
                    item(key = "notify-banner") {
                        NotificationDeniedBanner(
                            modifier = Modifier.animateItem(),
                            onOpenSettings = { NotificationPermission.openAppSettings(app) },
                        )
                    }
                }
                vm.askDurationQueue.firstOrNull()?.let { (title, planned) ->
                    item(key = "ask-duration") {
                        AskDurationCard(title = title, planned = planned, onAnswer = vm::answerActualDuration, onSkip = vm::skipActualDuration, modifier = Modifier.animateItem())
                    }
                }
                if (pinned.isNotEmpty()) {
                    item(key = "pinned-header") { SectionHeader(com.lodo.app.ui.L("重要的事", "Pinned")) }
                    items(pinned, key = { "pin-" + it.uuid }) { task -> TaskRowFor(task, state, vm, Modifier.animateItem()) }
                }
                if (state.due.isNotEmpty() && filter != TaskFilter.FUTURE) {
                    item(key = "due-header") { SectionHeader(stringResource(R.string.android_ui_due_now)) }
                    items(state.due.filter { !it.pinned }, key = { "due-${it.uuid}" }) { task ->
                        Box(Modifier.animateItem()) { DueCard(task = task, vm = vm, snoozeMinutes = state.snoozeMinutes) }
                    }
                    vm.rescheduleError?.let { error ->
                        item(key = "reschedule-error") {
                            Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                groups.forEach { (date, tasks) ->
                    item(key = "h-$date") { SectionHeader(dayHeader(date, today)) }
                    items(tasks, key = { it.uuid }) { task -> TaskRowFor(task, state, vm, Modifier.animateItem()) }
                }
                if (groups.isEmpty() && state.due.isEmpty() && pinned.isEmpty()) {
                    item(key = "empty") {
                        EmptyState(Icons.Outlined.CheckCircle, when (filter) {
                            TaskFilter.TODAY -> com.lodo.app.ui.L("今天没有要做的事了", "Nothing left for today")
                            TaskFilter.FUTURE -> com.lodo.app.ui.L("接下来没有安排", "Nothing upcoming")
                            else -> stringResource(R.string.shared_no_tasks_yet)
                        })
                    }
                }
                item(key = "bottom-spacer") { Spacer(Modifier.height(24.dp)) }
            }
        }
    }

    when (val sheet = vm.sheet) {
        is SheetMode.Add -> AddTaskSheet(
            allDayTime = state.allDayTime,
            agentSilenceTimeoutSeconds = state.agentSilenceTimeoutSeconds,
            onAiParse = vm::addParse,
            onSave = { vm.saveNew(it); vm.sheet = null },
            onDismiss = { vm.sheet = null },
        )
        is SheetMode.Create -> TaskEditSheet(
            existing = null, parsed = sheet.parsed, allDayTime = state.allDayTime, onAiEdit = vm::aiEdit,
            onSave = { vm.saveNew(it); vm.sheet = null }, onDismiss = { vm.sheet = null },
        )
        is SheetMode.Edit -> TaskEditSheet(
            existing = sheet.task, parsed = sheet.parsed, allDayTime = state.allDayTime, onAiEdit = vm::aiEdit,
            onSave = { vm.applyEdit(sheet.task.uuid, it); vm.sheet = null }, onDismiss = { vm.sheet = null },
        )
        null -> {}
    }
}

@Composable
private fun dayHeader(date: LocalDate, today: LocalDate): String {
    val locale = LocalConfiguration.current.locales[0]
    val text = date.format(com.lodo.app.ui.appFormatter(com.lodo.app.ui.L("M月d日 EEEE", "EEE, MMM d")))
    return when (date) {
        today -> com.lodo.app.ui.L("今天 · ", "Today · ") + text
        today.plusDays(1) -> com.lodo.app.ui.L("明天 · ", "Tomorrow · ") + text
        else -> if (date.isBefore(today)) com.lodo.app.ui.L("已逾期 · ", "Overdue · ") + text else text
    }
}

@Composable
private fun TaskRowFor(task: TaskEntity, state: TodoUiState, vm: TodoViewModel, modifier: Modifier) {
    var menu by remember { mutableStateOf(false) }
    Box(modifier) {
        PendingRow(
            task = task,
            hapticsEnabled = state.hapticsEnabled,
            onComplete = { vm.completeWithSampling(task) },
            onDelete = { vm.delete(task.uuid) },
            onClick = { vm.sheet = SheetMode.Edit(task) },
            onLongClick = { menu = true },
        )
        androidx.compose.material3.DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(if (task.pinned) com.lodo.app.ui.L("取消置顶", "Unpin") else com.lodo.app.ui.L("置顶", "Pin")) },
                onClick = { menu = false; vm.togglePin(task.uuid) },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(com.lodo.app.ui.L("稍等", "Snooze")) }, onClick = { menu = false; vm.snooze(task.uuid) },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(com.lodo.app.ui.L("编辑", "Edit")) }, onClick = { menu = false; vm.sheet = SheetMode.Edit(task) },
            )
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(com.lodo.app.ui.L("删除", "Delete"), color = MaterialTheme.colorScheme.error) },
                onClick = { menu = false; vm.delete(task.uuid) },
            )
        }
    }
}

/** 日期横滑条:今天起 30 天,选中项主色高亮。 */
@Composable
private fun DateStrip(selected: LocalDate, onSelect: (LocalDate) -> Unit) {
    val today = LocalDate.now()
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        LazyRow(
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items((0..29).toList()) { offset ->
                val date = today.plusDays(offset.toLong())
                val isSelected = date == selected
                val cellColor by animateColorAsState(
                    if (isSelected) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.surface,
                    label = "dateCell",
                )
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .defaultMinSize(minWidth = 44.dp, minHeight = 52.dp)
                        .background(cellColor, RoundedCornerShape(12.dp))
                        .clickable { onSelect(date) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Text(
                        if (date == today) stringResource(R.string.android_ui_today)
                        else localizedWeekdayLabels()[date.dayOfWeek.value - 1],
                        style = MaterialTheme.typography.labelSmall,
                        color = if (isSelected) MaterialTheme.colorScheme.onPrimary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "${date.dayOfMonth}",
                        style = MaterialTheme.typography.titleMedium,
                        color = if (isSelected) MaterialTheme.colorScheme.onPrimary
                        else MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }
    }
}

/** 通知权限被拒绝时的提示横幅:到期提醒可能不会推送,引导去系统设置开启。 */
@Composable
private fun NotificationDeniedBanner(onOpenSettings: () -> Unit, modifier: Modifier = Modifier) {
    ElevatedCard(modifier = modifier.fillMaxWidth().padding(top = 8.dp)) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.NotificationsOff, contentDescription = null)
            Text(
                stringResource(R.string.android_ui_notification_permission_disabled),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onOpenSettings) { Text(stringResource(R.string.android_ui_open_settings)) }
        }
    }
}

/** 完成后的实际耗时轻量条(智能采样,选择/跳过即消失)。 */
@Composable
private fun AskDurationCard(
    title: String,
    planned: Int,
    onAnswer: (Int) -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val chips = buildList {
        val lower = maxOf(5, (planned / 2 + 2) / 5 * 5)
        val upper = (planned * 3 / 2 + 2) / 5 * 5
        for (value in listOf(lower, planned, upper)) {
            if (value !in this) add(value)
        }
    }
    ElevatedCard(modifier = modifier.fillMaxWidth().padding(top = 8.dp)) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(stringResource(R.string.android_ui_how_long_did_0_actually_take, title), style = MaterialTheme.typography.bodyMedium)
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                chips.forEach { minutes ->
                    OutlinedButton(onClick = { onAnswer(minutes) }) {
                        Text(stringResource(R.string.android_ui_0_min, minutes))
                    }
                }
                TextButton(onClick = onSkip) { Text(stringResource(R.string.shared_skip)) }
            }
        }
    }
}

/** 到期提醒卡:标题行右侧「改期」,主操作行 完成/开始了 + 稍等,候选 chips 在下方。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DueCard(task: TaskEntity, vm: TodoViewModel, snoozeMinutes: Int) {
    val starting = task.phaseEnum == TaskPhase.START && task.durationMinutes > 0
    val taskCaption = localizedTaskCaption(task)
    val caption = when {
        task.phaseEnum == TaskPhase.END -> stringResource(R.string.android_ui_time_to_finish)
        starting -> stringResource(R.string.android_ui_duration_start_message_0, taskCaption)
        else -> taskCaption
    }
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Column(
            modifier = Modifier.padding(16.dp).animateContentSize(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    task.title,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { vm.requestReschedule(task) },
                    enabled = vm.rescheduleLoadingUuid == null,
                ) {
                    if (vm.rescheduleLoadingUuid == task.uuid) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.EditCalendar, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(stringResource(R.string.shared_reschedule))
                    }
                }
            }
            Text(
                caption,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { vm.completeWithSampling(task) }) {
                    Icon(
                        if (starting) Icons.Filled.PlayArrow else Icons.Filled.Check,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (starting) stringResource(R.string.android_ui_start_task)
                        else stringResource(R.string.android_ui_complete_action),
                    )
                }
                OutlinedButton(onClick = { vm.snooze(task.uuid) }) {
                    Icon(
                        Icons.Filled.HourglassEmpty,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(R.string.android_ui_snooze_0_min, snoozeMinutes))
                }
                OutlinedButton(onClick = { vm.ignore(task.uuid) }) {
                    Icon(
                        Icons.Filled.NotificationsOff,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(R.string.android_ui_ignore))
                }
            }
            vm.reschedule?.takeIf { it.first == task.uuid }?.let { (_, candidates) ->
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    candidates.forEach { (label, date) ->
                        OutlinedButton(onClick = { vm.applyReschedule(task.uuid, date) }) {
                            Text(label)
                        }
                    }
                    IconButton(onClick = vm::dismissReschedule) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.android_ui_collapse_suggestions))
                    }
                }
            }
        }
    }
}

/** 待办行:右滑完成、左滑删除(带振动),点击编辑。 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun PendingRow(
    task: TaskEntity,
    hapticsEnabled: Boolean,
    onComplete: () -> Unit,
    onDelete: () -> Unit,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: () -> Unit = {},
) {
    val haptics = LocalHapticFeedback.current
    val currentOnComplete by rememberUpdatedState(onComplete)
    val currentOnDelete by rememberUpdatedState(onDelete)
    val currentHaptics by rememberUpdatedState(hapticsEnabled)
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> {
                    if (currentHaptics) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    currentOnDelete()
                    true
                }
                SwipeToDismissBoxValue.StartToEnd -> {
                    if (currentHaptics) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    currentOnComplete()
                    false
                }
                else -> false
            }
        },
    )
    Column(modifier) {
        SwipeToDismissBox(
            state = dismissState,
            backgroundContent = { SwipeBackground(dismissState.dismissDirection) },
        ) {
            ListItem(
                leadingContent = {
                    IconButton(onClick = onComplete) {
                        Icon(Icons.Outlined.Circle, contentDescription = com.lodo.app.ui.L("完成", "Complete"),
                            tint = if (task.toData().isDue(java.time.LocalDateTime.now())) com.lodo.app.ui.theme.LodoColor.critical
                            else MaterialTheme.colorScheme.outline)
                    }
                },
                headlineContent = { Text(task.title, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium) },
                supportingContent = {
                    Text(localizedTaskCaption(task) + if (task.project.isNotBlank()) " · ${task.project}" else "")
                },
                trailingContent = if (task.pinned) ({ Icon(Icons.Filled.PushPin, null, tint = MaterialTheme.colorScheme.primary) }) else null,
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
            )
        }
    }
}

@Composable
private fun localizedTaskCaption(task: TaskEntity): String {
    val parts = mutableListOf(localizedDateTimeLabel(task.nextRemindAt))
    if (task.isRecurring) {
        val times = task.repeatTimesList.joinToString("/")
        val recurrence = when (task.repeatTypeEnum) {
            RepeatType.DAILY -> stringResource(R.string.shared_daily)
            RepeatType.WEEKLY -> {
                val days = localizedWeekdayList(task.repeatDaysList, compactChinese = true)
                val separator = if (LocalConfiguration.current.locales[0].language == "zh") "" else " "
                stringResource(R.string.android_ui_weekly_caption_prefix) + separator + days
            }
            RepeatType.NONE -> ""
        }
        parts += "$recurrence $times".trim()
    } else if (task.allDay) {
        parts += stringResource(R.string.shared_all_day)
    }
    if (task.durationMinutes > 0) {
        parts += stringResource(R.string.android_ui_0_min, task.durationMinutes)
    }
    if (task.phaseEnum == TaskPhase.END) {
        parts += stringResource(R.string.android_ui_in_progress)
    }
    return parts.joinToString(" · ")
}

/** 滑动背景:右滑完成为主色 + 对勾,左滑删除为错误色 + 垃圾桶。 */
@Composable
internal fun SwipeBackground(direction: SwipeToDismissBoxValue) {
    val (color, icon, alignment) = when (direction) {
        SwipeToDismissBoxValue.StartToEnd ->
            Triple(MaterialTheme.colorScheme.primary, Icons.Filled.Check, Alignment.CenterStart)
        SwipeToDismissBoxValue.EndToStart ->
            Triple(MaterialTheme.colorScheme.error, Icons.Filled.Delete, Alignment.CenterEnd)
        else -> return
    }
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(color)
            .padding(horizontal = 20.dp),
        contentAlignment = alignment,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.surface)
    }
}
