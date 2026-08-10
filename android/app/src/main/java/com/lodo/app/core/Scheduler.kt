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

    /** 用户点"稍等"——明确的正常交互,不是逃避,清零忽略连击。 */
    fun snooze(task: TaskData, now: LocalDateTime, snoozeMinutes: Int): TaskData =
        task.copy(nextRemindAt = now.plusMinutes(snoozeMinutes.toLong()), ignoreStreak = 0)

    /**
     * 用户明确点"忽略"(区别于弹出提醒但未操作时被动触发的 markNotified)。
     * 间隔按连续忽略次数逐次翻倍,封顶 240 分钟;streak 本身也封顶在 8
     * (2^8 倍已经远超上限,再往上纯粹是防 Int 溢出,对结果没有影响)。
     */
    fun ignore(task: TaskData, now: LocalDateTime, snoozeMinutes: Int): TaskData {
        val streak = minOf(task.ignoreStreak + 1, 8)
        val minutes = minOf(snoozeMinutes * (1 shl streak), 240)
        return task.copy(ignoreStreak = streak, nextRemindAt = now.plusMinutes(minutes.toLong()))
    }

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
            // 完成一次即视为"重新投入",忽略连击清零
            task.copy(phase = TaskPhase.START, remindAt = next, nextRemindAt = next, ignoreStreak = 0) to true
        } else {
            task.copy(status = TaskStatus.DONE, doneAt = now, ignoreStreak = 0) to true
        }
    }

    /**
     * 免打扰时段:仅影响通知实际弹出的时刻,不改变事项的到期/顺延语义
     * (nextRemindAt 的调度计算完全不经过这个函数,由调用方——AlarmScheduler——
     * 在真正排闹钟前对结果时间做一次调整)。quietStart == quietEnd 视为
     * 零宽窗口,等同于关闭。
     *
     * 跨零点(quietStart > quietEnd,如 22:00-08:00)时窗口分两段:
     * [quietStart, 24:00) 和 [00:00, quietEnd)。落在前一段,顺延到"次日" quietEnd;
     * 落在后一段,顺延到"当日" quietEnd。不跨零点时窗口是 [quietStart, quietEnd),
     * 顺延到"当日" quietEnd。
     */
    fun applyQuietHours(time: LocalDateTime, quietStart: String, quietEnd: String, enabled: Boolean): LocalDateTime {
        if (!enabled || quietStart == quietEnd) return time
        val s = TimeFormat.localTime(quietStart)
        val e = TimeFormat.localTime(quietEnd)
        val t = time.toLocalTime()
        val wraps = s > e
        val inWindow = if (wraps) (t >= s || t < e) else (t >= s && t < e)
        if (!inWindow) return time
        return if (wraps && t >= s) {
            time.toLocalDate().plusDays(1).atTime(e)
        } else {
            time.toLocalDate().atTime(e)
        }
    }
}
