package com.lodo.app.ui.todo

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.EmptyState
import com.lodo.app.ui.SectionHeader

/** 已完成标签页,对应 iOS DoneListView:本周洞察 + 右滑恢复未完成、左滑删除。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DoneListScreen(modifier: Modifier = Modifier, vm: TodoViewModel = viewModel()) {
    val state by vm.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(state.done.size) { vm.loadInsight() }

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("已完成") }) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            vm.insight?.let { insight ->
                item(key = "insight") {
                    Column {
                        SectionHeader("本周洞察")
                        ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    Icons.Filled.AutoAwesome,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(insight, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                }
            }

            if (state.done.isEmpty()) {
                item(key = "empty-done") {
                    EmptyState(Icons.Outlined.Inbox, "还没有完成的事项")
                }
            } else {
                items(state.done, key = { it.uuid }) { task ->
                    DoneRow(
                        task = task,
                        hapticsEnabled = state.hapticsEnabled,
                        onRestore = { vm.restore(task.uuid) },
                        onDelete = { vm.delete(task.uuid) },
                    )
                }
            }
        }
    }
}

/** 已完成行:右滑恢复为未完成,左滑删除(带振动)。 */
@Composable
private fun DoneRow(
    task: TaskEntity,
    hapticsEnabled: Boolean,
    onRestore: () -> Unit,
    onDelete: () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    val currentOnRestore by rememberUpdatedState(onRestore)
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
                    currentOnRestore()
                    true
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
