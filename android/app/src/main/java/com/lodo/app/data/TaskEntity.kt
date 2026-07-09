package com.lodo.app.data

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TaskData
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TaskStatus
import com.lodo.app.core.TimeFormat
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID

fun LocalDateTime.toEpochMillis(): Long =
    atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()

fun Long.toLocalDateTime(): LocalDateTime =
    Instant.ofEpochMilli(this).atZone(ZoneId.systemDefault()).toLocalDateTime()

/** 列表字段的 CSV 存取,如 [0, 4] ↔ "0,4"、["09:00", "21:00"] ↔ "09:00,21:00"。 */
fun joinCsv(values: List<String>): String = values.joinToString(",")
fun splitCsv(csv: String): List<String> = if (csv.isBlank()) emptyList() else csv.split(",")
fun joinIntCsv(values: List<Int>): String = values.joinToString(",")
fun splitIntCsv(csv: String): List<Int> =
    if (csv.isBlank()) emptyList() else csv.split(",").mapNotNull { it.toIntOrNull() }

/**
 * Room 持久化模型,字段与 iOS 版 TaskItem / web 版 tasks 表对齐;
 * 调度计算通过 TaskData 互转交给 core 层。
 */
@Entity(tableName = "tasks")
data class TaskEntity(
    @PrimaryKey val uuid: String,
    val title: String,
    val remindAtMillis: Long,
    val durationMinutes: Int,
    val allDay: Boolean,
    val repeatType: String,
    val repeatDays: String,
    val repeatTimes: String,
    val status: String,
    val phase: String,
    val nextRemindAtMillis: Long,
    val createdAtMillis: Long,
    val doneAtMillis: Long?,
) {
    val repeatTypeEnum: RepeatType get() = RepeatType.from(repeatType)
    val statusEnum: TaskStatus get() = TaskStatus.from(status)
    val phaseEnum: TaskPhase get() = TaskPhase.from(phase)
    val isRecurring: Boolean get() = repeatTypeEnum != RepeatType.NONE
    val repeatDaysList: List<Int> get() = splitIntCsv(repeatDays)
    val repeatTimesList: List<String> get() = splitCsv(repeatTimes)
    val remindAt: LocalDateTime get() = remindAtMillis.toLocalDateTime()
    val nextRemindAt: LocalDateTime get() = nextRemindAtMillis.toLocalDateTime()
    val doneAt: LocalDateTime? get() = doneAtMillis?.toLocalDateTime()

    /** 转成 core 层的纯数据结构做调度计算。 */
    fun toData() = TaskData(
        title = title, remindAt = remindAt, durationMinutes = durationMinutes,
        allDay = allDay, repeatType = repeatTypeEnum, repeatDays = repeatDaysList,
        repeatTimes = repeatTimesList, status = statusEnum, phase = phaseEnum,
        nextRemindAt = nextRemindAt, doneAt = doneAt,
    )

    /** 把调度计算结果写回模型。 */
    fun withData(d: TaskData) = copy(
        title = d.title,
        remindAtMillis = d.remindAt.toEpochMillis(),
        durationMinutes = d.durationMinutes,
        allDay = d.allDay,
        repeatType = d.repeatType.raw,
        repeatDays = joinIntCsv(d.repeatDays),
        repeatTimes = joinCsv(d.repeatTimes),
        status = d.status.raw,
        phase = d.phase.raw,
        nextRemindAtMillis = d.nextRemindAt.toEpochMillis(),
        doneAtMillis = d.doneAt?.toEpochMillis(),
    )

    /** 列表行的说明文字,如"今天 21:00 · 每天 07:00/21:00 · 45 分钟"。 */
    fun caption(): String {
        val parts = mutableListOf(TimeFormat.format(nextRemindAt))
        if (isRecurring) {
            parts += toData().repeatLabel
        } else if (allDay) {
            parts += "全天"
        }
        if (durationMinutes > 0) parts += "$durationMinutes 分钟"
        if (phaseEnum == TaskPhase.END) parts += "进行中"
        return parts.joinToString(" · ")
    }

    companion object {
        fun create(
            title: String,
            remindAt: LocalDateTime,
            durationMinutes: Int = 0,
            allDay: Boolean = false,
            repeatType: RepeatType = RepeatType.NONE,
            repeatDays: List<Int> = emptyList(),
            repeatTimes: List<String> = emptyList(),
            status: TaskStatus = TaskStatus.PENDING,
            doneAt: LocalDateTime? = null,
        ) = TaskEntity(
            uuid = UUID.randomUUID().toString(),
            title = title,
            remindAtMillis = remindAt.toEpochMillis(),
            durationMinutes = durationMinutes,
            allDay = allDay,
            repeatType = repeatType.raw,
            repeatDays = joinIntCsv(repeatDays),
            repeatTimes = joinCsv(repeatTimes),
            status = status.raw,
            phase = TaskPhase.START.raw,
            nextRemindAtMillis = remindAt.toEpochMillis(),
            createdAtMillis = LocalDateTime.now().toEpochMillis(),
            doneAtMillis = doneAt?.toEpochMillis(),
        )
    }
}
