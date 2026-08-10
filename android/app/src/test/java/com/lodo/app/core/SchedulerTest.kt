package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime

/** 调度核心逻辑测试,1:1 移植自 ios/LodoCore/Tests/LodoCoreTests/SchedulerTests.swift。 */
class SchedulerTest {
    // 2026-07-08 09:00,周三
    private val t0: LocalDateTime = LocalDateTime.of(2026, 7, 8, 9, 0)

    private fun makeTask(
        duration: Int = 0,
        repeatType: RepeatType = RepeatType.NONE,
        repeatDays: List<Int> = emptyList(),
        repeatTimes: List<String> = emptyList(),
    ) = TaskData(
        title = "测试", remindAt = t0, durationMinutes = duration,
        repeatType = repeatType, repeatDays = repeatDays, repeatTimes = repeatTimes,
    )

    @Test
    fun dueAtTime() {
        val t = makeTask()
        assertFalse(t.isDue(t0.minusMinutes(1)))
        assertTrue(t.isDue(t0))
        assertEquals(listOf(t), Scheduler.dueTasks(listOf(t), t0))
    }

    @Test
    fun ignoredReminderFiresAgainAfterSnooze() {
        // 弹出提醒,用户忽略
        val t = Scheduler.markNotified(makeTask(), t0, 15)
        assertFalse(t.isDue(t0.plusMinutes(14)))
        assertTrue(t.isDue(t0.plusMinutes(15)))
    }

    @Test
    fun explicitSnooze() {
        var t = Scheduler.markNotified(makeTask(), t0, 15)
        t = Scheduler.snooze(t, t0.plusMinutes(2), 15)
        assertEquals(t0.plusMinutes(17), t.nextRemindAt)
        assertEquals(TaskStatus.PENDING, t.status)
    }

    @Test
    fun completeZeroDuration() {
        val (t, done) = Scheduler.advance(makeTask(), t0.plusMinutes(1))
        assertTrue(done)
        assertEquals(TaskStatus.DONE, t.status)
        assertEquals(t0.plusMinutes(1), t.doneAt)
    }

    @Test
    fun durationTaskTwoPhase() {
        // 开始提醒 → 用户点"开始了"(晚了 5 分钟才开始)
        val startAt = t0.plusMinutes(5)
        val (started, doneFirst) = Scheduler.advance(makeTask(duration = 30), startAt)
        assertFalse(doneFirst)
        assertEquals(TaskStatus.PENDING, started.status)
        assertEquals(TaskPhase.END, started.phase)
        // 结束提醒基于实际开始时间 + 时长
        assertEquals(startAt.plusMinutes(30), started.nextRemindAt)
        assertTrue(started.isDue(startAt.plusMinutes(30)))
        // 结束提醒 → 点"完成"
        val (finished, doneSecond) = Scheduler.advance(started, startAt.plusMinutes(31))
        assertTrue(doneSecond)
        assertEquals(TaskStatus.DONE, finished.status)
    }

    @Test
    fun dailyMultipleTimes() {
        val t = makeTask(repeatType = RepeatType.DAILY, repeatTimes = listOf("09:00", "21:00"))
        // 9:00 当口 → 下一次是当天 21:00
        assertEquals(t0.plusHours(12), Scheduler.nextOccurrence(t, t0))
        // 21:00 之后 → 次日 9:00
        assertEquals(t0.plusHours(24), Scheduler.nextOccurrence(t, t0.plusHours(13)))
    }

    @Test
    fun weeklySelectedDays() {
        // 2026-07-08 是周三(0=周一 → 2);选周一、周五 8:00
        val t = makeTask(
            repeatType = RepeatType.WEEKLY, repeatDays = listOf(0, 4),
            repeatTimes = listOf("08:00"),
        )
        val friday = LocalDateTime.of(2026, 7, 10, 8, 0)
        val monday = LocalDateTime.of(2026, 7, 13, 8, 0)
        val next = Scheduler.nextOccurrence(t, t0)
        assertEquals(friday, next)  // 本周五
        assertEquals(monday, Scheduler.nextOccurrence(t, next!!))  // 下周一
    }

    @Test
    fun weeklyWithoutDaysIsInvalid() {
        val t = makeTask(repeatType = RepeatType.WEEKLY, repeatTimes = listOf("08:00"))
        assertNull(Scheduler.nextOccurrence(t, t0))
    }

    @Test
    fun recurringAdvanceSchedulesNext() {
        val (t, done) = Scheduler.advance(
            makeTask(repeatType = RepeatType.DAILY, repeatTimes = listOf("09:00")),
            t0.plusMinutes(3),
        )
        assertTrue(done)
        assertEquals(TaskStatus.PENDING, t.status)  // 重复事项本体不标记 done
        assertEquals(t0.plusHours(24), t.nextRemindAt)
    }

    @Test
    fun recurringWithDurationTwoPhase() {
        val task = makeTask(duration = 20, repeatType = RepeatType.DAILY, repeatTimes = listOf("09:00"))
        val (started, doneFirst) = Scheduler.advance(task, t0)  // 开始了 → 进入 end 阶段
        assertFalse(doneFirst)
        assertEquals(TaskPhase.END, started.phase)
        val (next, doneSecond) = Scheduler.advance(started, t0.plusMinutes(20))  // 完成一次
        assertTrue(doneSecond)
        assertEquals(TaskStatus.PENDING, next.status)
        assertEquals(TaskPhase.START, next.phase)
        assertEquals(t0.plusHours(24), next.nextRemindAt)
    }

    // MARK: - 忽略(显式动作,间隔逐次翻倍)

    @Test
    fun testExplicitIgnoreDoublesInterval() {
        val t = Scheduler.ignore(makeTask(), t0, 15)
        assertEquals(1, t.ignoreStreak)
        assertEquals(t0.plusMinutes(30), t.nextRemindAt)
        val t2 = Scheduler.ignore(t, t0.plusMinutes(30), 15)
        assertEquals(2, t2.ignoreStreak)
        assertEquals(t0.plusMinutes(30).plusMinutes(60), t2.nextRemindAt)
    }

    @Test
    fun testIgnoreStreakCapsAtMaxInterval() {
        var t = makeTask()
        repeat(10) { t = Scheduler.ignore(t, t0, 15) }
        assertEquals(8, t.ignoreStreak)  // streak 本身封顶
        assertEquals(t0.plusMinutes(240), t.nextRemindAt)  // 间隔封顶 240 分钟
    }

    @Test
    fun testIgnoreStreakResetsOnSnooze() {
        var t = Scheduler.ignore(makeTask(), t0, 15)
        t = Scheduler.ignore(t, t0, 15)
        assertEquals(2, t.ignoreStreak)
        t = Scheduler.snooze(t, t0, 15)
        assertEquals(0, t.ignoreStreak)
        assertEquals(t0.plusMinutes(15), t.nextRemindAt)
    }

    @Test
    fun testIgnoreStreakResetsOnComplete() {
        val ignored = Scheduler.ignore(makeTask(), t0, 15)
        assertEquals(1, ignored.ignoreStreak)
        val (doneTask, finished) = Scheduler.advance(ignored, t0.plusMinutes(1))
        assertTrue(finished)
        assertEquals(0, doneTask.ignoreStreak)

        // 重复事项完成一次同样清零
        val recurringIgnored = Scheduler.ignore(
            makeTask(repeatType = RepeatType.DAILY, repeatTimes = listOf("09:00")), t0, 15,
        )
        assertEquals(1, recurringIgnored.ignoreStreak)
        val (advanced, recurringFinished) = Scheduler.advance(recurringIgnored, t0.plusMinutes(1))
        assertTrue(recurringFinished)
        assertEquals(0, advanced.ignoreStreak)
    }

    // MARK: - 免打扰时段(仅影响通知弹出时刻,不影响到期状态)

    @Test
    fun testQuietHoursPushesTimeInsideWindowToWindowEnd() {
        // 09:00-18:00 免打扰,10:30 落在窗口内 → 顺延到当天 18:00
        val time = LocalDateTime.of(2026, 7, 8, 10, 30)
        val pushed = Scheduler.applyQuietHours(time, "09:00", "18:00", true)
        assertEquals(LocalDateTime.of(2026, 7, 8, 18, 0), pushed)
    }

    @Test
    fun testQuietHoursLeavesTimeOutsideWindowUnchanged() {
        val time = LocalDateTime.of(2026, 7, 8, 20, 0)
        val unchanged = Scheduler.applyQuietHours(time, "09:00", "18:00", true)
        assertEquals(time, unchanged)
    }

    @Test
    fun testQuietHoursHandlesOvernightWrap() {
        // 22:00-08:00 跨零点免打扰
        val evening = LocalDateTime.of(2026, 7, 8, 23, 30)
        assertEquals(
            LocalDateTime.of(2026, 7, 9, 8, 0),
            Scheduler.applyQuietHours(evening, "22:00", "08:00", true),
        )
        val earlyMorning = LocalDateTime.of(2026, 7, 8, 3, 0)
        assertEquals(
            LocalDateTime.of(2026, 7, 8, 8, 0),
            Scheduler.applyQuietHours(earlyMorning, "22:00", "08:00", true),
        )
        // 窗口边界外(如 08:00 本身、12:00)不受影响
        val boundary = LocalDateTime.of(2026, 7, 8, 8, 0)
        assertEquals(boundary, Scheduler.applyQuietHours(boundary, "22:00", "08:00", true))
        val daytime = LocalDateTime.of(2026, 7, 8, 12, 0)
        assertEquals(daytime, Scheduler.applyQuietHours(daytime, "22:00", "08:00", true))
    }

    @Test
    fun testQuietHoursDisabledOrZeroWidthLeavesTimeUnchanged() {
        val time = LocalDateTime.of(2026, 7, 8, 23, 30)
        assertEquals(time, Scheduler.applyQuietHours(time, "22:00", "08:00", false))
        assertEquals(time, Scheduler.applyQuietHours(time, "22:00", "22:00", true))
    }

    // MARK: - 补充:可读文案与时间工具

    @Test
    fun repeatLabels() {
        val daily = makeTask(repeatType = RepeatType.DAILY, repeatTimes = listOf("09:00", "21:00"))
        assertEquals("每天 09:00/21:00", daily.repeatLabel)
        val weekly = makeTask(
            repeatType = RepeatType.WEEKLY, repeatDays = listOf(2, 0),
            repeatTimes = listOf("08:00"),
        )
        assertEquals("每周一、三 08:00", weekly.repeatLabel)
        assertEquals("", makeTask().repeatLabel)
    }

    @Test
    fun timeFormatHelpers() {
        val day = LocalDate.of(2026, 7, 8)
        assertEquals(day.atTime(7, 30), TimeFormat.timeOn("07:30", day))
        assertEquals(day.atTime(9, 0), TimeFormat.timeOn("bad", day))  // 异常回退 9:00
        assertEquals("07:05", TimeFormat.hhmm(LocalTime.of(7, 5)))
        assertEquals("今天 21:00", TimeFormat.format(day.atTime(21, 0), today = day))
        assertEquals("明天 08:30", TimeFormat.format(day.plusDays(1).atTime(8, 30), today = day))
        assertEquals("7月15日 10:00", TimeFormat.format(LocalDateTime.of(2026, 7, 15, 10, 0), today = day))
    }
}
