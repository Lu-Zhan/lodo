import XCTest
@testable import LodoCore

/// 调度核心逻辑测试,移植自 web/tests/test_scheduler.py(每日汇总在 app 层用系统
/// UNCalendarNotificationTrigger 实现,不在核心逻辑内,对应用例不移植)。
final class SchedulerTests: XCTestCase {
    let calendar = Calendar.current
    // 2026-07-08 09:00,周三
    var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 0))!
    }

    func makeTask(
        duration: Int = 0, repeatType: RepeatType = .none,
        repeatDays: [Int] = [], repeatTimes: [String] = []
    ) -> TaskData {
        TaskData(title: "测试", remindAt: t0, durationMinutes: duration,
                 repeatType: repeatType, repeatDays: repeatDays, repeatTimes: repeatTimes)
    }

    func minutes(_ m: Int) -> TimeInterval { TimeInterval(m * 60) }

    func testDueAtTime() {
        let t = makeTask()
        XCTAssertFalse(t.isDue(now: t0.addingTimeInterval(-60)))
        XCTAssertTrue(t.isDue(now: t0))
        XCTAssertEqual(Scheduler.dueTasks([t], now: t0), [t])
    }

    func testIgnoredReminderFiresAgainAfterSnooze() {
        var t = makeTask()
        Scheduler.markNotified(&t, now: t0, snoozeMinutes: 15)  // 弹出提醒,用户忽略
        XCTAssertFalse(t.isDue(now: t0.addingTimeInterval(minutes(14))))
        XCTAssertTrue(t.isDue(now: t0.addingTimeInterval(minutes(15))))
    }

    func testExplicitSnooze() {
        var t = makeTask()
        Scheduler.markNotified(&t, now: t0, snoozeMinutes: 15)
        Scheduler.snooze(&t, now: t0.addingTimeInterval(minutes(2)), snoozeMinutes: 15)
        XCTAssertEqual(t.nextRemindAt, t0.addingTimeInterval(minutes(17)))
        XCTAssertEqual(t.status, .pending)
    }

    func testCompleteZeroDuration() {
        var t = makeTask()
        let done = Scheduler.advance(&t, now: t0.addingTimeInterval(minutes(1)))
        XCTAssertTrue(done)
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.doneAt, t0.addingTimeInterval(minutes(1)))
    }

    func testDurationTaskTwoPhase() {
        var t = makeTask(duration: 30)
        // 开始提醒 → 用户点"开始了"(晚了 5 分钟才开始)
        let startAt = t0.addingTimeInterval(minutes(5))
        XCTAssertFalse(Scheduler.advance(&t, now: startAt))
        XCTAssertEqual(t.status, .pending)
        XCTAssertEqual(t.phase, .end)
        // 结束提醒基于实际开始时间 + 时长
        XCTAssertEqual(t.nextRemindAt, startAt.addingTimeInterval(minutes(30)))
        XCTAssertTrue(t.isDue(now: startAt.addingTimeInterval(minutes(30))))
        // 结束提醒 → 点"完成"
        XCTAssertTrue(Scheduler.advance(&t, now: startAt.addingTimeInterval(minutes(31))))
        XCTAssertEqual(t.status, .done)
    }

    func testDailyMultipleTimes() {
        let t = makeTask(repeatType: .daily, repeatTimes: ["09:00", "21:00"])
        // 9:00 当口 → 下一次是当天 21:00
        XCTAssertEqual(Scheduler.nextOccurrence(t, after: t0),
                       t0.addingTimeInterval(minutes(12 * 60)))
        // 21:00 之后 → 次日 9:00
        XCTAssertEqual(Scheduler.nextOccurrence(t, after: t0.addingTimeInterval(minutes(13 * 60))),
                       t0.addingTimeInterval(minutes(24 * 60)))
    }

    func testWeeklySelectedDays() {
        // 2026-07-08 是周三(pyWeekday=2);选周一、周五 8:00
        let t = makeTask(repeatType: .weekly, repeatDays: [0, 4], repeatTimes: ["08:00"])
        let friday = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 10, hour: 8, minute: 0))!
        let monday = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 13, hour: 8, minute: 0))!
        let next = Scheduler.nextOccurrence(t, after: t0)
        XCTAssertEqual(next, friday)  // 本周五
        XCTAssertEqual(Scheduler.nextOccurrence(t, after: next!), monday)  // 下周一
    }

    func testWeeklyWithoutDaysIsInvalid() {
        let t = makeTask(repeatType: .weekly, repeatTimes: ["08:00"])
        XCTAssertNil(Scheduler.nextOccurrence(t, after: t0))
    }

    func testRecurringAdvanceSchedulesNext() {
        var t = makeTask(repeatType: .daily, repeatTimes: ["09:00"])
        let done = Scheduler.advance(&t, now: t0.addingTimeInterval(minutes(3)))
        XCTAssertTrue(done)
        XCTAssertEqual(t.status, .pending)  // 重复事项本体不标记 done
        XCTAssertEqual(t.nextRemindAt, t0.addingTimeInterval(minutes(24 * 60)))
    }

    func testRecurringWithDurationTwoPhase() {
        var t = makeTask(duration: 20, repeatType: .daily, repeatTimes: ["09:00"])
        XCTAssertFalse(Scheduler.advance(&t, now: t0))  // 开始了 → 进入 end 阶段
        XCTAssertEqual(t.phase, .end)
        XCTAssertTrue(Scheduler.advance(&t, now: t0.addingTimeInterval(minutes(20))))  // 完成一次
        XCTAssertEqual(t.status, .pending)
        XCTAssertEqual(t.phase, .start)
        XCTAssertEqual(t.nextRemindAt, t0.addingTimeInterval(minutes(24 * 60)))
    }
}
