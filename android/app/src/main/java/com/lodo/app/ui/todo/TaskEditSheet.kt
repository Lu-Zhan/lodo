package com.lodo.app.ui.todo

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Scheduler
import com.lodo.app.core.TaskData
import com.lodo.app.core.TimeFormat
import com.lodo.app.core.weekdayNames
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import com.lodo.app.ui.SectionHeader
import com.lodo.app.ui.StepperRow
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val dayFormatter = DateTimeFormatter.ofPattern("yyyy年M月d日")

/** 创建/编辑共用表单;编辑模式下支持 AI 自然语言指令修改。对应 iOS TaskEditView。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TaskEditSheet(
    existing: TaskEntity?,
    parsed: ParsedTask?,
    allDayTime: String,
    onAiEdit: suspend (ParsedTask, String) -> ParsedTask,
    onSave: (ParsedTask) -> Unit,
    onDismiss: () -> Unit,
) {
    val source: ParsedTask? = remember {
        parsed ?: existing?.let {
            ParsedTask(
                title = it.title, remindAt = it.remindAt, allDay = it.allDay,
                durationMinutes = it.durationMinutes, repeatType = it.repeatTypeEnum,
                repeatDays = it.repeatDaysList, repeatTimes = it.repeatTimesList,
            )
        }
    }
    val base = remember { source?.remindAt ?: LocalDateTime.now().plusMinutes(5) }

    var title by remember { mutableStateOf(source?.title ?: "") }
    var repeatType by remember { mutableStateOf(source?.repeatType ?: RepeatType.NONE) }
    var day by remember { mutableStateOf(base.toLocalDate()) }
    var time by remember { mutableStateOf(base.toLocalTime().withSecond(0).withNano(0)) }
    var allDay by remember { mutableStateOf(source?.allDay ?: false) }
    var weekdays by remember {
        mutableStateOf<Set<Int>>(source?.repeatDays?.toSet() ?: emptySet())
    }
    var times by remember {
        mutableStateOf<List<String>>(
            source?.repeatTimes?.map { TimeFormat.hhmm(TimeFormat.localTime(it)) } ?: emptyList()
        )
    }
    var duration by remember { mutableIntStateOf(source?.durationMinutes ?: 0) }

    var aiInstruction by remember { mutableStateOf("") }
    var aiBusy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }
    var editingTimeIndex by remember { mutableStateOf<Int?>(null) }

    val scope = rememberCoroutineScope()

    val isValid = title.isNotBlank() && when (repeatType) {
        RepeatType.NONE -> true
        RepeatType.DAILY -> times.isNotEmpty()
        RepeatType.WEEKLY -> times.isNotEmpty() && weekdays.isNotEmpty()
    }

    /** 当前表单值 → ParsedTask(重复事项 remindAt 取下一次发生时间),对应 iOS makeParsed。 */
    fun makeParsed(): ParsedTask? {
        if (!isValid) return null
        val trimmed = title.trim()
        val timeStrings = times.map { TimeFormat.hhmm(TimeFormat.localTime(it)) }.distinct().sorted()
        if (repeatType == RepeatType.NONE) {
            return ParsedTask(
                title = trimmed,
                remindAt = if (allDay) TimeFormat.timeOn(allDayTime, day) else day.atTime(time),
                allDay = allDay,
                durationMinutes = duration,
                repeatType = RepeatType.NONE,
                repeatDays = emptyList(),
                repeatTimes = emptyList(),
            )
        }
        val now = LocalDateTime.now()
        val probe = TaskData(
            title = trimmed, remindAt = now, repeatType = repeatType,
            repeatDays = if (repeatType == RepeatType.WEEKLY) weekdays.sorted() else emptyList(),
            repeatTimes = timeStrings,
        )
        val first = Scheduler.nextOccurrence(probe, now) ?: return null
        return ParsedTask(
            title = trimmed, remindAt = first, allDay = false,
            durationMinutes = duration, repeatType = repeatType,
            repeatDays = probe.repeatDays, repeatTimes = timeStrings,
        )
    }

    fun save() {
        val result = makeParsed()
        if (result == null) {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSave(result)
    }

    fun applyAi() {
        val instruction = aiInstruction.trim()
        val current = makeParsed()
        if (instruction.isEmpty() || aiBusy || current == null) return
        scope.launch {
            aiBusy = true
            errorText = null
            try {
                val updated = onAiEdit(current, instruction)
                title = updated.title
                repeatType = updated.repeatType
                allDay = updated.allDay
                day = updated.remindAt.toLocalDate()
                time = updated.remindAt.toLocalTime()
                weekdays = updated.repeatDays.toSet()
                times = updated.repeatTimes.map { TimeFormat.hhmm(TimeFormat.localTime(it)) }
                duration = updated.durationMinutes
                aiInstruction = ""
            } catch (e: Exception) {
                errorText = e.message
            } finally {
                aiBusy = false
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding()
                .imePadding(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("取消") }
                Text(
                    if (existing == null) "新建事项" else "编辑事项",
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = ::save, enabled = isValid) { Text("保存") }
            }

            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("事项内容") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            SectionHeader("重复")
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf(RepeatType.NONE to "不重复", RepeatType.DAILY to "每天", RepeatType.WEEKLY to "每周")
                    .forEachIndexed { index, (type, label) ->
                        SegmentedButton(
                            selected = repeatType == type,
                            onClick = { repeatType = type },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                        ) { Text(label) }
                    }
            }

            if (repeatType == RepeatType.NONE) {
                ValueRow("日期", day.format(dayFormatter)) { showDatePicker = true }
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("全天", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    Switch(checked = allDay, onCheckedChange = { allDay = it })
                }
                if (!allDay) {
                    ValueRow("时间", TimeFormat.hhmm(time)) { showTimePicker = true }
                } else {
                    FooterText("全天事项将在当天 $allDayTime 提醒(可在设置中修改)")
                }
            } else {
                if (repeatType == RepeatType.WEEKLY) {
                    SectionHeader("周几")
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (i in 0..6) {
                            FilterChip(
                                selected = i in weekdays,
                                onClick = {
                                    weekdays = if (i in weekdays) weekdays - i else weekdays + i
                                },
                                label = { Text(weekdayNames[i].drop(1)) },
                            )
                        }
                    }
                }
                SectionHeader("提醒时间点")
                times.forEachIndexed { i, hhmm ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(
                            modifier = Modifier
                                .weight(1f)
                                .clickable { editingTimeIndex = i }
                                .padding(vertical = 12.dp),
                        ) {
                            Text("时间 ${i + 1}", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Text(hhmm, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                        }
                        IconButton(onClick = { times = times.filterIndexed { j, _ -> j != i } }) {
                            Icon(Icons.Filled.Close, contentDescription = "删除时间点")
                        }
                    }
                }
                TextButton(onClick = { times = times + "09:00" }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("添加时间点")
                }
            }

            SectionHeader("时长")
            StepperRow(
                label = "时长:" + if (duration == 0) "无" else "$duration 分钟",
                onDecrement = { duration = (duration - 5).coerceAtLeast(0) },
                onIncrement = { duration = (duration + 5).coerceAtMost(480) },
            )
            FooterText("有时长的事项会在开始和结束各提醒一次")

            if (existing != null) {
                SectionHeader("AI 修改")
                OutlinedTextField(
                    value = aiInstruction,
                    onValueChange = { aiInstruction = it },
                    placeholder = { Text("例如:改到明天晚上8点 / 改成每天早晚各提醒一次") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(
                    onClick = ::applyAi,
                    enabled = !aiBusy && aiInstruction.isNotBlank(),
                    modifier = Modifier.padding(top = 8.dp),
                ) {
                    if (aiBusy) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.width(4.dp))
                    Text("应用修改")
                }
            }

            errorText?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    if (showDatePicker) {
        // DatePicker 以 UTC 零点毫秒表示所选日期
        val dateState = rememberDatePickerState(
            initialSelectedDateMillis = day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dateState.selectedDateMillis?.let {
                        day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()
                    }
                    showDatePicker = false
                }) { Text("确定") }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text("取消") }
            },
        ) {
            DatePicker(state = dateState)
        }
    }

    if (showTimePicker) {
        LodoTimePickerDialog(
            initial = time,
            onConfirm = {
                time = it
                showTimePicker = false
            },
            onDismiss = { showTimePicker = false },
        )
    }

    editingTimeIndex?.let { index ->
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(times.getOrNull(index) ?: "09:00"),
            onConfirm = { picked ->
                times = times.mapIndexed { j, old -> if (j == index) TimeFormat.hhmm(picked) else old }
                editingTimeIndex = null
            },
            onDismiss = { editingTimeIndex = null },
        )
    }
}

/** 标签 + 可点值的行(日期/时间选择入口)。 */
@Composable
private fun ValueRow(label: String, value: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
    }
}
