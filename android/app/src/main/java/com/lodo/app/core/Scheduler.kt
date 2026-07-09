package com.lodo.app.core

import java.time.LocalDateTime

/**
 * 提醒调度核心逻辑,移植自 ios/LodoCore 的 Scheduler.swift(源头是 web/lodo/scheduler.py)。
 * 纯函数操作 TaskData,由调用方负责持久化与闹钟/通知重排。
 * TaskData 不可变,变更以返回副本表达(对应 Swift 版的 inout)。
 */
object Scheduler {

    /** 返回此刻应当弹出提醒的事项。 */
    fun dueTasks(tasks: List<TaskData>, now: LocalDateTime): List<TaskData> =
        tasks.filter { it.isDue(now) }

    /** 弹出提醒的同时把下次提醒自动顺延——忽略提醒也会在间隔后再次提醒。 */
    fun markNotified(task: TaskData, now: LocalDateTime, snoozeMinutes: Int): TaskData =
        task.copy(nextRemindAt = now.plusMinutes(snoozeMinutes.toLong()))

    /** 用户点"稍等"。 */
    fun snooze(task: TaskData, now: LocalDateTime, snoozeMinutes: Int): TaskData =
        task.copy(nextRemindAt = now.plusMinutes(snoozeMinutes.toLong()))

    /**
     * 重复事项在 after 之后的下一次提醒时间。
     * 每日:每天在 repeatTimes 各提醒一次;每周:仅在 repeatDays 选中的周几提醒。
     */
    fun nextOccurrence(task: TaskData, after: LocalDateTime): LocalDateTime? {
        if (!task.isRecurring || task.repeatTimes.isEmpty()) return null
        if (task.repeatType == RepeatType.WEEKLY && task.repeatDays.isEmpty()) return null
        val days = if (task.repeatType == RepeatType.DAILY) (0..6).toSet() else task.repeatDays.toSet()
        val times = task.repeatTimes.sorted()
        for (offset in 0..7) {  // 最多一周内必有下一次
            val day = after.toLocalDate().plusDays(offset.toLong())
            // DayOfWeek.value: 1=周一…7=周日 → 转为 0=周一…6=周日
            if (day.dayOfWeek.value - 1 !in days) continue
            for (hhmm in times) {
                val parts = hhmm.split(":").mapNotNull { it.toIntOrNull() }
                if (parts.size != 2 || parts[0] !in 0..23 || parts[1] !in 0..59) continue
                val candidate = day.atTime(parts[0], parts[1])
                if (candidate.isAfter(after)) return candidate
            }
        }
        return null
    }

    /**
     * 用户对提醒做出肯定响应。返回 (更新后的事项, 是否完成了一次或整个事项)。
     *
     * - 时长 > 0 且处于开始阶段:表示"开始做了",转入结束阶段,
     *   在实际开始时间 + 时长后提醒确认完成,finished 为 false。
     * - 其余情况即完成:一次性事项标记 done;重复事项排到下一次提醒。
     */
    fun advance(task: TaskData, now: LocalDateTime): Pair<TaskData, Boolean> {
        if (task.phase == TaskPhase.START && task.durationMinutes > 0) {
            return task.copy(
                phase = TaskPhase.END,
                nextRemindAt = now.plusMinutes(task.durationMinutes.toLong()),
            ) to false
        }
        val next = nextOccurrence(task, now)
        return if (next != null) {
            task.copy(phase = TaskPhase.START, remindAt = next, nextRemindAt = next) to true
        } else {
            task.copy(status = TaskStatus.DONE, doneAt = now) to true
        }
    }
}
