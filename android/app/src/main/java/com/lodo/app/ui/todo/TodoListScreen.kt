package com.lodo.app.ui.todo

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.weekdayNames
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.EmptyState
import com.lodo.app.ui.SectionHeader
import java.time.LocalDate
import java.time.format.DateTimeFormatter

private val monthDayFormatter = DateTimeFormatter.ofPattern("M月d日")

/**
 * 待办标签页,对应 iOS TodoListView:日期横滑条(默认今天)、到期提醒卡
 * (完成/稍等 + 右上角改期)、今天/未来待办分组、实际耗时轻量条。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodoListScreen(
    modifier: Modifier = Modifier,
    onOpenSettings: () -> Unit = {},
    vm: TodoViewModel = viewModel(),
) {
    val state by vm.uiState.collectAsStateWithLifecycle()

    val dueUuids = state.due.map { it.uuid }.toSet()
    val upcoming = state.pending.filter { it.uuid !in dueUuids }
    val dayTasks = upcoming.filter { it.nextRemindAt.toLocalDate() == vm.selectedDate }
    val futureTasks = upcoming.filter { it.nextRemindAt.toLocalDate() > vm.selectedDate }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("lodo") },
                actions = {
                    IconButton(onClick = { vm.sheet = SheetMode.Agent() }) {
                        Icon(Icons.Filled.AutoAwesome, contentDescription = "AI 助手")
                    }
                    IconButton(onClick = onOpenSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "设置")
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { vm.sheet = SheetMode.Add }) {
                Icon(Icons.Filled.Add, contentDescription = "添加")
            }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            item(key = "date-strip") { DateStrip(vm.selectedDate) { vm.selectedDate = it } }

            vm.askDuration?.let { (title, planned) ->
                item(key = "ask-duration") {
                    AskDurationCard(
                        title = title,
                        planned = planned,
                        onAnswer = vm::answerActualDuration,
                        onSkip = vm::skipActualDuration,
                    )
                }
            }

            if (state.due.isNotEmpty()) {
                item(key = "due-header") { SectionHeader("🔔 到期提醒") }
                items(state.due, key = { "due-${it.uuid}" }) { task ->
                    DueCard(task = task, vm = vm, snoozeMinutes = state.snoozeMinutes)
                }
                vm.rescheduleError?.let { error ->
                    item(key = "reschedule-error") {
                        Text(
                            error,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            item(key = "day-header") {
                SectionHeader(
                    if (vm.selectedDate == LocalDate.now()) "今天待办"
                    else "${vm.selectedDate.format(monthDayFormatter)}待办"
                )
            }
            if (upcoming.isEmpty() && state.due.isEmpty()) {
                item(key = "empty-pending") {
                    EmptyState(Icons.Outlined.CheckCircle, "暂无待办事项")
                }
            } else if (dayTasks.isEmpty()) {
                item(key = "empty-day") {
                    Text(
                        "当天暂无待办",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp),
                    )
                }
            }
            items(dayTasks, key = { it.uuid }) { task ->
                PendingRow(
                    task = task,
                    hapticsEnabled = state.hapticsEnabled,
                    onComplete = { vm.completeWithSampling(task) },
                    onDelete = { vm.delete(task.uuid) },
                    onClick = { vm.sheet = SheetMode.Edit(task) },
                )
            }

            if (futureTasks.isNotEmpty()) {
                item(key = "future-header") { SectionHeader("未来待办") }
                items(futureTasks, key = { "future-${it.uuid}" }) { task ->
                    PendingRow(
                        task = task,
                        hapticsEnabled = state.hapticsEnabled,
                        onComplete = { vm.completeWithSampling(task) },
                        onDelete = { vm.delete(task.uuid) },
                        onClick = { vm.sheet = SheetMode.Edit(task) },
                    )
                }
            }

            item(key = "fab-spacer") { Spacer(Modifier.height(80.dp)) }
        }
    }

    when (val sheet = vm.sheet) {
        is SheetMode.Add -> AddTaskSheet(
            allDayTime = state.allDayTime,
            onAiParse = vm::addParse,
            onSave = {
                vm.saveNew(it)
                vm.sheet = null
            },
            onDismiss = { vm.sheet = null },
        )
        is SheetMode.Agent -> AgentSheet(
            prefill = sheet.prefill,
            onSubmit = vm::agentRoute,
            onConfirm = { vm.performPendingActions() },
            onDismiss = { vm.sheet = null },
        )
        is SheetMode.Create -> TaskEditSheet(
            existing = null,
            parsed = sheet.parsed,
            allDayTime = state.allDayTime,
            onAiEdit = vm::aiEdit,
            onSave = {
                vm.saveNew(it)
                vm.sheet = null
            },
            onDismiss = { vm.sheet = null },
        )
        is SheetMode.Edit -> TaskEditSheet(
            existing = sheet.task,
            parsed = sheet.parsed,
            allDayTime = state.allDayTime,
            onAiEdit = vm::aiEdit,
            onSave = {
                vm.applyEdit(sheet.task.uuid, it)
                vm.sheet = null
            },
            onDismiss = { vm.sheet = null },
        )
        null -> {}
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
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .background(
                            if (isSelected) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.surface,
                            RoundedCornerShape(12.dp),
                        )
                        .clickable { onSelect(date) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Text(
                        if (date == today) "今天" else weekdayNames[date.dayOfWeek.value - 1],
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

/** 完成后的实际耗时轻量条(智能采样,选择/跳过即消失)。 */
@Composable
private fun AskDurationCard(
    title: String,
    planned: Int,
    onAnswer: (Int) -> Unit,
    onSkip: () -> Unit,
) {
    val chips = buildList {
        val lower = maxOf(5, (planned / 2 + 2) / 5 * 5)
        val upper = (planned * 3 / 2 + 2) / 5 * 5
        for (value in listOf(lower, planned, upper)) {
            if (value !in this) add(value)
        }
    }
    ElevatedCard(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("「$title」实际用了多久?", style = MaterialTheme.typography.bodyMedium)
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                chips.forEach { minutes ->
                    OutlinedButton(onClick = { onAnswer(minutes) }) { Text("$minutes 分钟") }
                }
                TextButton(onClick = onSkip) { Text("跳过") }
            }
        }
    }
}

/** 到期提醒卡:标题行右侧「改期」,主操作行 完成/开始了 + 稍等,候选 chips 在下方。 */
@Composable
private fun DueCard(task: TaskEntity, vm: TodoViewModel, snoozeMinutes: Int) {
    val starting = task.phaseEnum == TaskPhase.START && task.durationMinutes > 0
    val caption = when {
        task.phaseEnum == TaskPhase.END -> "时间到 — 完成了吗?"
        starting -> "${task.caption()} — 该开始了!"
        else -> task.caption()
    }
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
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
                        Text("改期")
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
                    Text(if (starting) "开始了" else "完成")
                }
                OutlinedButton(onClick = { vm.snooze(task.uuid) }) {
                    Icon(
                        Icons.Filled.HourglassEmpty,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("稍等 $snoozeMinutes 分钟")
                }
            }
            vm.reschedule?.takeIf { it.first == task.uuid }?.let { (_, candidates) ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    candidates.forEach { (label, date) ->
                        OutlinedButton(onClick = { vm.applyReschedule(task.uuid, date) }) {
                            Text(label)
                        }
                    }
                    IconButton(onClick = vm::dismissReschedule) {
                        Icon(Icons.Filled.Close, contentDescription = "收起改期候选")
                    }
                }
            }
        }
    }
}

/** 待办行:右滑完成、左滑删除(带振动),点击编辑。 */
@Composable
internal fun PendingRow(
    task: TaskEntity,
    hapticsEnabled: Boolean,
    onComplete: () -> Unit,
    onDelete: () -> Unit,
    onClick: () -> Unit,
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
    Column {
        SwipeToDismissBox(
            state = dismissState,
            backgroundContent = { SwipeBackground(dismissState.dismissDirection) },
        ) {
            ListItem(
                headlineContent = { Text(task.title) },
                supportingContent = { Text(task.caption()) },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                modifier = Modifier.clickable(onClick = onClick),
            )
        }
        HorizontalDivider()
    }
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
