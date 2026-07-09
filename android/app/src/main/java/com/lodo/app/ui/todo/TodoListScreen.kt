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
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Inbox
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.EmptyState
import com.lodo.app.ui.SectionHeader

/** 待办标签页:自然语言创建、到期提醒卡、待办/已完成列表。对应 iOS TodoListView。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodoListScreen(modifier: Modifier = Modifier, vm: TodoViewModel = viewModel()) {
    val state by vm.uiState.collectAsStateWithLifecycle()
    var listTab by rememberSaveable { mutableIntStateOf(0) }

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("lodo") }) },
        floatingActionButton = {
            FloatingActionButton(onClick = { vm.sheet = SheetMode.Create(null) }) {
                Icon(Icons.Filled.Add, contentDescription = "新建事项")
            }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            item(key = "nl") { NaturalLanguageField(vm) }

            if (state.due.isNotEmpty()) {
                item(key = "due-header") { SectionHeader("🔔 到期提醒") }
                items(state.due, key = { "due-${it.uuid}" }) { task ->
                    DueCard(
                        task = task,
                        snoozeMinutes = state.snoozeMinutes,
                        onComplete = { vm.complete(task.uuid) },
                        onSnooze = { vm.snooze(task.uuid) },
                    )
                }
            }

            item(key = "segmented") {
                SingleChoiceSegmentedButtonRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 16.dp, bottom = 8.dp),
                ) {
                    listOf("待办", "已完成").forEachIndexed { index, label ->
                        SegmentedButton(
                            selected = listTab == index,
                            onClick = { listTab = index },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                        ) { Text(label) }
                    }
                }
            }

            if (listTab == 0) {
                if (state.pending.isEmpty()) {
                    item(key = "empty-pending") {
                        EmptyState(Icons.Outlined.CheckCircle, "暂无待办事项")
                    }
                } else {
                    items(state.pending, key = { it.uuid }) { task ->
                        PendingRow(
                            task = task,
                            onComplete = { vm.complete(task.uuid) },
                            onDelete = { vm.delete(task.uuid) },
                            onClick = { vm.sheet = SheetMode.Edit(task) },
                        )
                    }
                }
            } else {
                if (state.done.isEmpty()) {
                    item(key = "empty-done") {
                        EmptyState(Icons.Outlined.Inbox, "还没有完成的事项")
                    }
                } else {
                    items(state.done, key = { it.uuid }) { task ->
                        DoneRow(task = task, onDelete = { vm.delete(task.uuid) })
                    }
                }
            }

            item(key = "fab-spacer") { Spacer(Modifier.height(80.dp)) }
        }
    }

    when (val sheet = vm.sheet) {
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
            parsed = null,
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

/** 自然语言输入框 + AI 解析按钮。 */
@Composable
private fun NaturalLanguageField(vm: TodoViewModel) {
    Column {
        SectionHeader("自然语言创建")
        OutlinedTextField(
            value = vm.nlText,
            onValueChange = { vm.nlText = it },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("例如:明天下午3点开会一小时") },
            singleLine = true,
            trailingIcon = {
                if (vm.aiBusy) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = vm::parseNL, enabled = vm.nlText.isNotBlank()) {
                        Icon(Icons.Filled.AutoAwesome, contentDescription = "AI 解析")
                    }
                }
            },
        )
        vm.aiError?.let {
            Text(
                it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/** 到期提醒卡:完成/开始了 + 稍等按钮,文案对应 iOS dueCaption。 */
@Composable
private fun DueCard(
    task: TaskEntity,
    snoozeMinutes: Int,
    onComplete: () -> Unit,
    onSnooze: () -> Unit,
) {
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
            Text(task.title, style = MaterialTheme.typography.titleMedium)
            Text(
                caption,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onComplete) {
                    Icon(
                        if (starting) Icons.Filled.PlayArrow else Icons.Filled.Check,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(if (starting) "开始了" else "完成")
                }
                OutlinedButton(onClick = onSnooze) {
                    Icon(
                        Icons.Filled.HourglassEmpty,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("稍等 $snoozeMinutes 分钟")
                }
            }
        }
    }
}

/** 待办行:右滑完成(重复事项完成后留在列表,回弹)、左滑删除,点击编辑。 */
@Composable
private fun PendingRow(
    task: TaskEntity,
    onComplete: () -> Unit,
    onDelete: () -> Unit,
    onClick: () -> Unit,
) {
    val currentOnComplete by rememberUpdatedState(onComplete)
    val currentOnDelete by rememberUpdatedState(onDelete)
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.EndToStart -> {
                    currentOnDelete()
                    true
                }
                SwipeToDismissBoxValue.StartToEnd -> {
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

/** 已完成行:删除线 + 完成时间,仅可左滑删除。 */
@Composable
private fun DoneRow(task: TaskEntity, onDelete: () -> Unit) {
    val currentOnDelete by rememberUpdatedState(onDelete)
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                currentOnDelete()
                true
            } else {
                false
            }
        },
    )
    Column {
        SwipeToDismissBox(
            state = dismissState,
            enableDismissFromStartToEnd = false,
            backgroundContent = { SwipeBackground(dismissState.dismissDirection) },
        ) {
            ListItem(
                headlineContent = {
                    Text(task.title, textDecoration = TextDecoration.LineThrough)
                },
                supportingContent = {
                    task.doneAt?.let { Text("完成于 ${TimeFormat.format(it)}") }
                },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
            )
        }
        HorizontalDivider()
    }
}

/** 滑动背景:右滑完成为主色 + 对勾,左滑删除为错误色 + 垃圾桶。 */
@Composable
private fun SwipeBackground(direction: SwipeToDismissBoxValue) {
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
