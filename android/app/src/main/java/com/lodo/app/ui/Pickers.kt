package com.lodo.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

private val dateFmt get() = com.lodo.app.ui.appFormatter(L("yyyy年M月d日 E", "EEE, MMM d, yyyy"))
private val timeFmt = com.lodo.app.ui.appFormatter("HH:mm")

/** M3 日期选择对话框(DatePicker 以 UTC 毫秒为准,这里换算成 LocalDate)。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LodoDatePickerDialog(initial: LocalDate, onConfirm: (LocalDate) -> Unit, onDismiss: () -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initial.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { onConfirm(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) }
                onDismiss()
            }) { Text(L("确定", "OK")) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(L("取消", "Cancel")) } },
    ) { DatePicker(state = state) }
}

/** 一行「日期 [时间]」两个胶囊,点开各自的选择器。showTime = false 时只有日期。 */
@Composable
fun DateTimeField(
    label: String,
    value: LocalDateTime,
    showTime: Boolean,
    onChange: (LocalDateTime) -> Unit,
    modifier: Modifier = Modifier,
) {
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        AssistChip(onClick = { pickDate = true }, label = { Text(value.format(dateFmt)) },
            leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null) })
        if (showTime) AssistChip(onClick = { pickTime = true }, label = { Text(value.format(timeFmt)) },
            leadingIcon = { Icon(Icons.Outlined.Schedule, null) })
    }
    if (pickDate) LodoDatePickerDialog(value.toLocalDate(), { onChange(it.atTime(value.toLocalTime())) }, { pickDate = false })
    if (pickTime) LodoTimePickerDialog(value.toLocalTime(), { onChange(value.toLocalDate().atTime(it)); pickTime = false }, { pickTime = false })
}

fun LocalDate.atTimeOrMidnight(time: LocalTime?) = atTime(time ?: LocalTime.MIDNIGHT)
