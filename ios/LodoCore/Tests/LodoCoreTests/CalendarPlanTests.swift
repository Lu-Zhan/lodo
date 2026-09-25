import XCTest
@testable import LodoCore

/// 周条与日历事件的纯逻辑单测(不碰 EventKit,不需要模拟器、不需要日历授权)。
/// 基准时间沿用 SchedulerTests 的 2026-07-08 09:00(周三)。
final class CalendarPlanTests: XCTestCase {
    let calendar = Calendar.current
    var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 0))!
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: - 周计算

    /// 周三所在的周,第一天是同一周的周一(7 月 6 日)。
    func testWeekStartsOnMonday() {
        XCTAssertEqual(CalendarWeek.start(of: t0, calendar: calendar), date(7, 6))
    }

    /// 周日属于**上一个**周一开头的那一周,不是下一周(0 = 周一的口径)。
    func testSundayBelongsToTheWeekThatStartedMonday() {
        let sunday = date(7, 12, 23, 30)
        XCTAssertEqual(CalendarWeek.start(of: sunday, calendar: calendar), date(7, 6))
    }

    func testDaysContainingCoversMondayThroughSunday() {
        let days = CalendarWeek.days(containing: t0, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, date(7, 6))
        XCTAssertEqual(days.last, date(7, 12))
    }

    func testShiftMovesWholeWeeks() {
        let start = CalendarWeek.start(of: t0, calendar: calendar)
        XCTAssertEqual(CalendarWeek.shift(start, byWeeks: 1, calendar: calendar), date(7, 13))
        XCTAssertEqual(CalendarWeek.shift(start, byWeeks: -2, calendar: calendar), date(6, 22))
    }

    // MARK: - 抬头文案

    func testLabelWithinSameMonth() {
        XCTAssertEqual(CalendarWeek.label(for: date(7, 6), calendar: calendar), "7月6-12日")
    }

    func testLabelAcrossMonths() {
        XCTAssertEqual(CalendarWeek.label(for: date(6, 29), calendar: calendar), "6月29日-7月5日")
    }

    func testLabelAcrossYears() {
        XCTAssertEqual(CalendarWeek.label(for: date(12, 28), calendar: calendar),
                       "12月28日-2027年1月3日")
    }

    // MARK: - 事件归日

    private func event(_ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: "e", title: "会议", start: start, end: end,
                      isAllDay: allDay, calendarTitle: "工作")
    }

    func testTimedEventOccursOnItsOwnDay() {
        let e = event(date(7, 8, 10), date(7, 8, 11))
        XCTAssertTrue(e.occurs(on: date(7, 8), calendar: calendar))
        XCTAssertFalse(e.occurs(on: date(7, 7), calendar: calendar))
        XCTAssertFalse(e.occurs(on: date(7, 9), calendar: calendar))
    }

    /// 跨天的事件在中间那几天也要看得见(区间相交,不是只看开始那天)。
    func testMultiDayEventOccursOnEveryDayItSpans() {
        let e = event(date(7, 6, 20), date(7, 9, 8))
        for day in 6...9 {
            XCTAssertTrue(e.occurs(on: date(7, day), calendar: calendar), "7/\(day)")
        }
        XCTAssertFalse(e.occurs(on: date(7, 10), calendar: calendar))
    }

    /// 全天事件的 endDate 通常是次日零点,不能因此多算出一天来。
    func testAllDayEventDoesNotLeakIntoTheNextDay() {
        let e = event(date(7, 8), date(7, 9), allDay: true)
        XCTAssertTrue(e.occurs(on: date(7, 8), calendar: calendar))
        XCTAssertFalse(e.occurs(on: date(7, 9), calendar: calendar))
    }

    /// 全天事件排当天最前面(没有具体时间,夹在定时事项中间读不出先后)。
    func testAllDaySortsFirstWithinTheDay() {
        let allDay = event(date(7, 8), date(7, 9), allDay: true)
        let timed = event(date(7, 8, 10), date(7, 8, 11))
        XCTAssertLessThan(allDay.sortDate(on: date(7, 8), calendar: calendar),
                          timed.sortDate(on: date(7, 8), calendar: calendar))
    }

    // MARK: - 任务镜像

    private func task(title: String = "开会", remindAt: Date, duration: Int = 0,
                      allDay: Bool = false, status: TaskStatus = .pending,
                      repeatType: RepeatType = .none,
                      nextRemindAt: Date? = nil) -> TaskData {
        TaskData(title: title, remindAt: remindAt, durationMinutes: duration, allDay: allDay,
                 repeatType: repeatType, repeatDays: repeatType == .weekly ? [2] : [],
                 repeatTimes: repeatType == .none ? [] : ["09:00"],
                 status: status, phase: .start,
                 nextRemindAt: nextRemindAt ?? remindAt)
    }

    func testMirrorUsesDurationWhenPresent() {
        let uuid = UUID()
        let mirror = CalendarTaskMirror.from(task(remindAt: date(7, 8, 10), duration: 45),
                                             uuid: uuid)
        XCTAssertEqual(mirror?.start, date(7, 8, 10))
        XCTAssertEqual(mirror?.end, date(7, 8, 10, 45))
        XCTAssertEqual(mirror?.uuid, uuid)
    }

    /// 没填时长的补默认半小时:日历事件必须有长度,零长度在周/月视图里看不见。
    func testMirrorFallsBackToDefaultDuration() {
        let mirror = CalendarTaskMirror.from(task(remindAt: date(7, 8, 10)), uuid: UUID())
        XCTAssertEqual(mirror?.end,
                       date(7, 8, 10).addingTimeInterval(
                        TimeInterval(CalendarTaskMirror.defaultDurationMinutes * 60)))
    }

    /// 已完成的不镜像——完成了就该从日历上消失。
    func testDoneTaskIsNotMirrored() {
        XCTAssertNil(CalendarTaskMirror.from(
            task(remindAt: date(7, 8, 10), status: .done), uuid: UUID()))
    }

    /// 重复事项镜像的是**下一次**发生,不是最初那条 remindAt。
    func testRecurringTaskMirrorsNextOccurrence() {
        let mirror = CalendarTaskMirror.from(
            task(remindAt: date(7, 1, 9), repeatType: .weekly,
                 nextRemindAt: date(7, 8, 9)), uuid: UUID())
        XCTAssertEqual(mirror?.start, date(7, 8, 9))
    }

    func testEventURLRoundTrip() {
        let uuid = UUID()
        let mirror = CalendarTaskMirror(uuid: uuid, title: "开会", start: t0,
                                        end: t0.addingTimeInterval(1800), isAllDay: false)
        XCTAssertEqual(CalendarTaskMirror.taskUUID(fromEventURL: mirror.eventURL), uuid)
    }

    /// 不是 lodo 写的事件(用户自己建的)认不出 uuid,同步时不会被当成孤儿删掉。
    func testForeignEventURLIsNotClaimed() {
        XCTAssertNil(CalendarTaskMirror.taskUUID(
            fromEventURL: URL(string: "https://example.com/meeting")))
        XCTAssertNil(CalendarTaskMirror.taskUUID(fromEventURL: nil))
    }
}
