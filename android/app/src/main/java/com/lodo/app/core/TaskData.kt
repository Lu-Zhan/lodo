package com.lodo.app.core

import java.time.LocalDateTime

/** 事项状态。rawValue 与 web/iOS 版持久化字符串一致。 */
enum class TaskStatus(val raw: String) {
    PENDING("pending"),
    DONE("done");

    companion object {
        fun from(raw: String): TaskStatus = entries.firstOrNull { it.raw == raw } ?: PENDING
    }
}

/** 时长事项的阶段:等待开始提醒 / 已开始等待结束提醒。 */
enum class TaskPhase(val raw: String) {
    START("start"),
    END("end");

    companion object {
        fun from(raw: String): TaskPhase = entries.firstOrNull { it.raw == raw } ?: START
    }
}

/** 重复类型。 */
enum class RepeatType(val raw: String) {
    NONE("none"),
    DAILY("daily"),
    WEEKLY("weekly");

    companion object {
        fun from(raw: String): RepeatType = entries.firstOrNull { it.raw == raw } ?: NONE
    }
}

val weekdayNames = listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

/** 平台无关的事项数据,语义与 ios/LodoCore 的 TaskData、web 版 models.py 的 Task 一一对应。 */
data class TaskData(
    val title: String,
    val remindAt: LocalDateTime,
    val durationMinutes: Int = 0,
    val allDay: Boolean = false,
    val repeatType: RepeatType = RepeatType.NONE,
    /** 每周重复选中的周几,0=周一 … 6=周日。 */
    val repeatDays: List<Int> = emptyList(),
    /** 重复事项每天的提醒时间点,"HH:MM"。 */
    val repeatTimes: List<String> = emptyList(),
    val status: TaskStatus = TaskStatus.PENDING,
    val phase: TaskPhase = TaskPhase.START,
    val nextRemindAt: LocalDateTime = remindAt,
    val doneAt: LocalDateTime? = null,
) {
    val isRecurring: Boolean get() = repeatType != RepeatType.NONE

    /** 重复规则的可读描述,如"每周一、三 09:00/21:00"。 */
    val repeatLabel: String
        get() {
            if (!isRecurring) return ""
            val times = repeatTimes.joinToString("/")
            if (repeatType == RepeatType.DAILY) return "每天 $times"
            val days = repeatDays.sorted().joinToString("、") { weekdayNames[it].drop(1) }
            return "每周$days $times"
        }

    fun isDue(now: LocalDateTime): Boolean =
        status == TaskStatus.PENDING && !now.isBefore(nextRemindAt)
}
