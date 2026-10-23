package com.lodo.app.ui.routine

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.lodo.app.core.RepeatType
import com.lodo.app.data.RoutineEntity
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.ui.L
import com.lodo.app.ui.localizedWeekdayChipLabel
import java.time.LocalDateTime
import java.time.LocalTime

/** 单次/每天/每周,保留一天多个时间点;编辑不会默默丢掉首个时间以外的计划。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun RoutineEditSheet(
    existing: RoutineEntity? = null,
    onSave: (prompt: String, remindAt: LocalDateTime, repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>) -> Unit,
    onDelete: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var prompt by remember { mutableStateOf(existing?.prompt.orEmpty()) }
    var type by remember { mutableStateOf(existing?.repeatTypeEnum ?: RepeatType.DAILY) }
    var days by remember { mutableStateOf(existing?.repeatDaysList?.toSet() ?: emptySet()) }
    var timesText by remember { mutableStateOf(existing?.repeatTimesList?.joinToString(", ")?.ifBlank { "09:00" } ?: "09:00") }
    var singleText by remember { mutableStateOf((existing?.remindAtMillis?.toLocalDateTime() ?: LocalDateTime.now().plusHours(1)).withSecond(0).withNano(0).toString().replace('T', ' ')) }
    var confirmDelete by remember { mutableStateOf(false) }
    val single = runCatching { LocalDateTime.parse(singleText.trim().replace(' ', 'T')) }.getOrNull()
    val times = runCatching {
        timesText.split(',', '，', '、').map { it.trim() }.filter { it.isNotEmpty() }.map {
            require(it.matches(Regex("[0-9]{2}:[0-9]{2}"))); LocalTime.parse(it).toString()
        }.distinct().sorted()
    }.getOrNull()
    val valid = prompt.isNotBlank() && when (type) {
        RepeatType.NONE -> single != null
        RepeatType.DAILY -> !times.isNullOrEmpty()
        RepeatType.WEEKLY -> !times.isNullOrEmpty() && days.isNotEmpty()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            com.lodo.app.ui.assets.SheetHeader(L("定时任务", "Routine"), valid, onDismiss) {
                val at = if (type == RepeatType.NONE) requireNotNull(single) else LocalDateTime.now().toLocalDate().atTime(LocalTime.parse(requireNotNull(times).first()))
                onSave(prompt.trim(), at, type, if (type == RepeatType.WEEKLY) days.sorted() else emptyList(), if (type == RepeatType.NONE) emptyList() else times.orEmpty())
            }
            OutlinedTextField(prompt, { prompt = it }, label = { Text(L("指令", "Instruction")) }, minLines = 2, modifier = Modifier.fillMaxWidth())
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf(RepeatType.NONE to L("不重复", "Once"), RepeatType.DAILY to L("每天", "Daily"), RepeatType.WEEKLY to L("每周", "Weekly")).forEachIndexed { index, (value, label) ->
                    SegmentedButton(type == value, { type = value }, shape = SegmentedButtonDefaults.itemShape(index, 3)) { Text(label) }
                }
            }
            if (type == RepeatType.NONE) OutlinedTextField(singleText, { singleText = it }, label = { Text(L("触发日期时间(YYYY-MM-DD HH:mm)", "Date/time (YYYY-MM-DD HH:mm)")) }, isError = single == null, modifier = Modifier.fillMaxWidth())
            else {
                OutlinedTextField(timesText, { timesText = it }, label = { Text(L("触发时间(HH:mm,多个用逗号分隔)", "Times (HH:mm, comma separated)")) }, isError = times.isNullOrEmpty(), modifier = Modifier.fillMaxWidth())
                if (type == RepeatType.WEEKLY) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    (0..6).forEach { day -> FilterChip(day in days, { days = if (day in days) days - day else days + day }, label = { Text(localizedWeekdayChipLabel(day)) }) }
                }
            }
            existing?.lastResultText?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            if (onDelete != null) OutlinedButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) { Text(L("删除定时任务", "Delete routine"), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text(L("删除定时任务?", "Delete routine?")) },
        confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete?.invoke(); onDismiss() }) { Text(L("删除", "Delete")) } }, dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("取消", "Cancel")) } })
}
