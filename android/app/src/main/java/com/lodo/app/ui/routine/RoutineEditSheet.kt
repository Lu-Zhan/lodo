package com.lodo.app.ui.routine

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TimeFormat
import com.lodo.app.core.weekdayNames
import com.lodo.app.data.RoutineEntity
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import java.time.LocalDateTime

/** 新建/编辑定时任务,对应 iOS RoutineEditView 的核心子集:指令原话 + 每天/
 * 每周的触发时间点,不含"不重复"单次任务(大多数例行任务本身就是要反复跑的,
 * 这一轮先覆盖 daily/weekly——与设置页"每日汇总"的时间选择是同一套模式)。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RoutineEditSheet(
    existing: RoutineEntity? = null,
    onSave: (prompt: String, remindAt: LocalDateTime, repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>) -> Unit,
    onDelete: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var prompt by remember { mutableStateOf(existing?.prompt.orEmpty()) }
    var repeatType by remember {
        mutableStateOf(if (existing?.repeatTypeEnum == RepeatType.WEEKLY) RepeatType.WEEKLY else RepeatType.DAILY)
    }
    var days by remember { mutableStateOf(existing?.repeatDaysList?.toSet() ?: setOf(0)) }
    var time by remember { mutableStateOf(existing?.repeatTimesList?.firstOrNull() ?: "09:00") }
    var showTimePicker by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.shared_cancel)) }
                Text(
                    stringResource(R.string.android_ui_routine),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                TextButton(
                    onClick = {
                        val repeatDays = if (repeatType == RepeatType.WEEKLY) days.sorted() else emptyList()
                        val baseline = TimeFormat.localTime(time)
                        val remindAt = LocalDateTime.now().withHour(baseline.hour).withMinute(baseline.minute)
                            .withSecond(0).withNano(0)
                        onSave(prompt.trim(), remindAt, repeatType, repeatDays, listOf(time))
                    },
                    enabled = prompt.isNotBlank() && (repeatType != RepeatType.WEEKLY || days.isNotEmpty()),
                ) { Text(stringResource(R.string.android_ui_save)) }
            }
            OutlinedTextField(
                value = prompt, onValueChange = { prompt = it },
                label = { Text(stringResource(R.string.android_ui_routine_instruction)) },
                placeholder = { Text(stringResource(R.string.android_ui_routine_placeholder)) },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf(RepeatType.DAILY to stringResource(R.string.shared_daily), RepeatType.WEEKLY to stringResource(R.string.shared_weekly))
                    .forEachIndexed { index, (type, label) ->
                        SegmentedButton(
                            selected = repeatType == type,
                            onClick = { repeatType = type },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                        ) { Text(label) }
                    }
            }
            if (repeatType == RepeatType.WEEKLY) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (i in 0..6) {
                        FilterChip(
                            selected = i in days,
                            onClick = { days = if (i in days) days - i else days + i },
                            label = { Text(weekdayNames[i].drop(1)) },
                        )
                    }
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth().clickable(onClick = { showTimePicker = true }).padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.android_ui_trigger_time), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Text(time, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
            }
            existing?.lastResultText?.let { last ->
                FooterText(stringResource(R.string.android_ui_last_result_0, last))
            }
            if (onDelete != null) {
                OutlinedButton(onClick = { onDelete(); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.android_ui_delete_routine), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }

    if (showTimePicker) {
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(time),
            onConfirm = { time = TimeFormat.hhmm(it); showTimePicker = false },
            onDismiss = { showTimePicker = false },
        )
    }
}
