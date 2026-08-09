package com.lodo.app.ui.routine

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Alarm
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TimeFormat
import com.lodo.app.core.weekdayNames
import com.lodo.app.data.RoutineEntity
import com.lodo.app.ui.EmptyState

/** 定时任务(AI 例行任务)列表,对应 iOS RoutineListView。从设置页进入。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoutineListScreen(onBack: () -> Unit, vm: RoutineViewModel = viewModel()) {
    val routines by vm.routines.collectAsStateWithLifecycle()
    var editUuid by remember { mutableStateOf<String?>(null) }
    var showAdd by remember { mutableStateOf(false) }
    var showNewUuid by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.android_ui_routine)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.android_ui_back))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAdd = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.android_ui_routine))
            }
        },
    ) { padding ->
        if (routines.isEmpty()) {
            EmptyState(
                Icons.Outlined.Alarm, stringResource(R.string.android_ui_no_routines_yet),
                modifier = Modifier.fillMaxSize().padding(padding),
            )
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(bottom = 80.dp),
            ) {
                items(routines, key = { it.uuid }) { routine ->
                    RoutineRow(
                        routine = routine,
                        onToggle = { vm.setEnabled(routine.uuid, it) },
                        onClick = { editUuid = routine.uuid },
                    )
                    HorizontalDivider()
                }
            }
        }
    }

    if (showAdd) {
        RoutineEditSheet(
            onSave = { prompt, remindAt, repeatType, repeatDays, repeatTimes ->
                vm.save(prompt, remindAt, repeatType, repeatDays, repeatTimes)
                showAdd = false
            },
            onDismiss = { showAdd = false },
        )
    }

    editUuid?.let { uuid ->
        routines.firstOrNull { it.uuid == uuid }?.let { routine ->
            RoutineEditSheet(
                existing = routine,
                onSave = { prompt, remindAt, repeatType, repeatDays, repeatTimes ->
                    vm.update(uuid, prompt, remindAt, repeatType, repeatDays, repeatTimes)
                    editUuid = null
                },
                onDelete = { vm.delete(uuid) },
                onDismiss = { editUuid = null },
            )
        }
    }
}

@Composable
private fun RoutineRow(routine: RoutineEntity, onToggle: (Boolean) -> Unit, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        headlineContent = {
            Text(routine.prompt, maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        supportingContent = {
            val schedule = if (routine.repeatTypeEnum == RepeatType.WEEKLY) {
                routine.repeatDaysList.joinToString("、") { weekdayNames[it] } + " " + routine.repeatTimesList.firstOrNull().orEmpty()
            } else {
                stringResource(R.string.shared_daily) + " " + routine.repeatTimesList.firstOrNull().orEmpty()
            }
            Text(
                routine.lastRunAt?.let { "$schedule · ${stringResource(R.string.android_ui_last_run_0, TimeFormat.format(it))}" } ?: schedule,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        trailingContent = { Switch(checked = routine.enabled, onCheckedChange = onToggle) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
    )
}
