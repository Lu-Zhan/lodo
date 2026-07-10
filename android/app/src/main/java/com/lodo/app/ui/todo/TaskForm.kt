package com.lodo.app.ui.todo

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Scheduler
import com.lodo.app.core.TaskData
import com.lodo.app.core.TimeFormat
import com.lodo.app.core.weekdayNames
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import com.lodo.app.ui.SectionHeader
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val dayFormatter = DateTimeFormatter.ofPattern("yyyy年M月d日")

/**
 * 创建/编辑表单的字段值与校验、转换逻辑,
 * TaskEditSheet 与 AddTaskSheet 的手动输入模块共用。对应 iOS TaskFormModel。
 */
@Stable
class TaskFormState(source: ParsedTask?) {
    private val base = source?.remindAt ?: LocalDateTime.now().plusMinutes(5)

    var title by mutableStateOf(source?.title ?: "")
    var repeatType by mutableStateOf(source?.repeatType ?: RepeatType.NONE)
    var day by mutableStateOf(base.toLocalDate())
    var time by mutableStateOf(base.toLocalTime().withSecond(0).withNano(0))
    var allDay by mutableStateOf(source?.allDay ?: false)
    var weekdays by mutableStateOf<Set<Int>>(source?.repeatDays?.toSet() ?: emptySet())
    var times by mutableStateOf<List<String>>(
        source?.repeatTimes?.map { TimeFormat.hhmm(TimeFormat.localTime(it)) } ?: emptyList()
    )
    var duration by mutableIntStateOf(source?.durationMinutes ?: 0)

    val isValid: Boolean
        get() = title.isNotBlank() && when (repeatType) {
            RepeatType.NONE -> true
            RepeatType.DAILY -> times.isNotEmpty()
            RepeatType.WEEKLY -> times.isNotEmpty() && weekdays.isNotEmpty()
        }

    /** 当前表单值 → ParsedTask(重复事项 remindAt 取下一次发生时间)。 */
    fun makeParsed(allDayTime: String): ParsedTask? {
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

    /** 用 AI 返回的字段覆盖当前表单值。 */
    fun apply(parsed: ParsedTask) {
        title = parsed.title
        repeatType = parsed.repeatType
        allDay = parsed.allDay
        day = parsed.remindAt.toLocalDate()
        time = parsed.remindAt.toLocalTime().withSecond(0).withNano(0)
        weekdays = parsed.repeatDays.toSet()
        times = parsed.repeatTimes.map { TimeFormat.hhmm(TimeFormat.localTime(it)) }
        duration = parsed.durationMinutes
    }
}

@Composable
fun rememberTaskFormState(source: ParsedTask?): TaskFormState =
    remember { TaskFormState(source) }

/**
 * 表单字段区块,对应 iOS TaskFormSections。
 * aiFilled:首区块标题旁显示"AI 已填写"徽标;suggestedDuration:时长行高亮为 AI 建议。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TaskFormFields(
    state: TaskFormState,
    allDayTime: String,
    header: String? = null,
    aiFilled: Boolean = false,
    suggestedDuration: Boolean = false,
) {
    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }
    var editingTimeIndex by remember { mutableStateOf<Int?>(null) }

    Column {
        if (header != null || aiFilled) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                header?.let { SectionHeader(it) }
                if (aiFilled) {
                    Spacer(Modifier.width(8.dp))
                    Icon(
                        Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(16.dp).padding(top = 4.dp),
                    )
                    Text(
                        "AI 已填写",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 12.dp, start = 2.dp),
                    )
                }
            }
        }

        OutlinedTextField(
            value = state.title,
            onValueChange = { state.title = it },
            label = { Text("事项内容") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        SectionHeader("重复")
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            listOf(RepeatType.NONE to "不重复", RepeatType.DAILY to "每天", RepeatType.WEEKLY to "每周")
                .forEachIndexed { index, (type, label) ->
                    SegmentedButton(
                        selected = state.repeatType == type,
                        onClick = {
                            state.repeatType = type
                            // 切到重复模式时补一个默认时间点,避免保存按钮无提示地不可用
                            if (type != RepeatType.NONE && state.times.isEmpty()) {
                                state.times = listOf("09:00")
                            }
                        },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                    ) { Text(label) }
                }
        }

        if (state.repeatType == RepeatType.NONE) {
            FormValueRow("日期", state.day.format(dayFormatter)) { showDatePicker = true }
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("全天", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Switch(checked = state.allDay, onCheckedChange = { state.allDay = it })
            }
            if (!state.allDay) {
                FormValueRow("时间", TimeFormat.hhmm(state.time)) { showTimePicker = true }
            } else {
                FooterText("全天事项将在当天 $allDayTime 提醒(可在设置中修改)")
            }
        } else {
            if (state.repeatType == RepeatType.WEEKLY) {
                SectionHeader("周几")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (i in 0..6) {
                        FilterChip(
                            selected = i in state.weekdays,
                            onClick = {
                                state.weekdays =
                                    if (i in state.weekdays) state.weekdays - i else state.weekdays + i
                            },
                            label = { Text(weekdayNames[i].drop(1)) },
                        )
                    }
                }
            }
            SectionHeader("提醒时间点")
            state.times.forEachIndexed { i, hhmm ->
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
                    IconButton(onClick = {
                        state.times = state.times.filterIndexed { j, _ -> j != i }
                    }) {
                        Icon(Icons.Filled.Close, contentDescription = "删除时间点")
                    }
                }
            }
            TextButton(onClick = { state.times = state.times + "09:00" }) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text("添加时间点")
            }
        }

        SectionHeader("时长")
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (suggestedDuration) {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(4.dp))
            }
            Text(
                "时长:" + if (state.duration == 0) "无" else "${state.duration} 分钟",
                style = MaterialTheme.typography.bodyLarge,
                color = if (suggestedDuration) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { state.duration = (state.duration - 5).coerceAtLeast(0) }) { Text("−") }
            TextButton(onClick = { state.duration = (state.duration + 5).coerceAtMost(480) }) { Text("+") }
        }
        if (suggestedDuration) {
            FooterText("时长为 AI 参考历史类似事项的建议")
        }
        FooterText("有时长的事项会在开始和结束各提醒一次")
    }

    if (showDatePicker) {
        // DatePicker 以 UTC 零点毫秒表示所选日期
        val dateState = rememberDatePickerState(
            initialSelectedDateMillis = state.day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dateState.selectedDateMillis?.let {
                        state.day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()
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
            initial = state.time,
            onConfirm = {
                state.time = it
                showTimePicker = false
            },
            onDismiss = { showTimePicker = false },
        )
    }

    editingTimeIndex?.let { index ->
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(state.times.getOrNull(index) ?: "09:00"),
            onConfirm = { picked ->
                state.times = state.times.mapIndexed { j, old ->
                    if (j == index) TimeFormat.hhmm(picked) else old
                }
                editingTimeIndex = null
            },
            onDismiss = { editingTimeIndex = null },
        )
    }
}

/** 标签 + 可点值的行(日期/时间选择入口)。 */
@Composable
internal fun FormValueRow(label: String, value: String, onClick: () -> Unit) {
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
