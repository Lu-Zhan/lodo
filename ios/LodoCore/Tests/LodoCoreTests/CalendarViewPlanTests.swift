import XCTest
@testable import LodoCore

/// 日历页几种视图的区间/翻页/排版纯逻辑(不碰 EventKit)。
/// 基准时间沿用 SchedulerTests 的 2026-07-08 09:00(周三)。
final class CalendarViewPlanTests: XCTestCase {
    let calendar = Calendar.current
    var t0: Date { date(7, 8, 9) }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, calendarTitle: "")
    }

    // MARK: - 锚点与翻页

    func testAnchors() {
        XCTAssertEqual(CalendarViewPlan.anchor(for: t0, mode: .day, calendar: calendar), date(7, 8))
        XCTAssertEqual(CalendarViewPlan.anchor(for: t0, mode: .threeDay, calendar: calendar), date(7, 8))
        XCTAssertEqual(CalendarViewPlan.anchor(for: t0, mode: .week, calendar: calendar), date(7, 6))
        XCTAssertEqual(CalendarViewPlan.anchor(for: t0, mode: .month, calendar: calendar), date(7, 1))
        XCTAssertEqual(CalendarViewPlan.anchor(for: t0, mode: .year, calendar: calendar), date(1, 1))
    }

    func testShiftPages() {
        XCTAssertEqual(CalendarViewPlan.shift(date(7, 8), mode: .day, by: -1, calendar: calendar), date(7, 7))
        XCTAssertEqual(CalendarViewPlan.shift(date(7, 8), mode: .threeDay, by: 1, calendar: calendar), date(7, 11))
        XCTAssertEqual(CalendarViewPlan.shift(date(7, 6), mode: .week, by: 1, calendar: calendar), date(7, 13))
        XCTAssertEqual(CalendarViewPlan.shift(date(1, 1), mode: .month, by: -1, calendar: calendar),
                       date(12, 1, year: 2025))
        XCTAssertEqual(CalendarViewPlan.shift(date(1, 1), mode: .year, by: 1, calendar: calendar),
                       date(1, 1, year: 2027))
        // 所有列表不翻页。
        XCTAssertEqual(CalendarViewPlan.shift(date(7, 8), mode: .agenda, by: 3, calendar: calendar), date(7, 8))
    }

    func testTimelineDays() {
        XCTAssertEqual(CalendarViewPlan.timelineDays(anchor: t0, mode: .day, calendar: calendar), [date(7, 8)])
        XCTAssertEqual(CalendarViewPlan.timelineDays(anchor: t0, mode: .threeDay, calendar: calendar),
                       [date(7, 8), date(7, 9), date(7, 10)])
        let week = CalendarViewPlan.timelineDays(anchor: t0, mode: .week, calendar: calendar)
        XCTAssertEqual(week.first, date(7, 6))
        XCTAssertEqual(week.last, date(7, 12))
        XCTAssertTrue(CalendarViewPlan.timelineDays(anchor: t0, mode: .month, calendar: calendar).isEmpty)
    }

    // MARK: - 月格子

    /// 2026 年 7 月:1 号是周三,31 号是周五 → 从 6/29 周一到 8/2 周日,5 行。
    func testMonthGridStartsMondayAndFillsWholeWeeks() {
        let grid = CalendarViewPlan.monthGrid(for: t0, calendar: calendar)
        XCTAssertEqual(grid.count, 35)
        XCTAssertEqual(grid.first, date(6, 29))
        XCTAssertEqual(grid.last, date(8, 2))
    }

    /// 2026 年 3 月:1 号是周日 → 格子从 2/23 起,要 6 行。
    func testMonthGridSixRowsWhenFirstIsSunday() {
        let grid = CalendarViewPlan.monthGrid(for: date(3, 15), calendar: calendar)
        XCTAssertEqual(grid.count, 42)
        XCTAssertEqual(grid.first, date(2, 23))
        XCTAssertEqual(grid.last, date(4, 5))
    }

    func testYearMonths() {
        let months = CalendarViewPlan.months(ofYear: t0, calendar: calendar)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first, date(1, 1))
        XCTAssertEqual(months.last, date(12, 1))
    }

    // MARK: - 查询区间

    func testQueryRanges() {
        XCTAssertEqual(CalendarViewPlan.queryRange(anchor: date(7, 6), mode: .week, calendar: calendar),
                       date(7, 6)..<date(7, 13))
        XCTAssertEqual(CalendarViewPlan.queryRange(anchor: date(7, 1), mode: .month, calendar: calendar),
                       date(6, 29)..<date(8, 3))
        let agenda = CalendarViewPlan.queryRange(anchor: t0, mode: .agenda, now: t0, calendar: calendar)
        XCTAssertEqual(agenda.lowerBound, date(6, 8))
        XCTAssertEqual(agenda.upperBound, calendar.date(byAdding: .day, value: 365, to: date(7, 8)))
    }

    // MARK: - 列表分组

    /// 跨三天的全天事件在三天里都出现;全天事件排在当天定时事件前面;
    /// 全天事件 endDate 卡在次日零点,不多出一天。
    func testAgendaGroupsSpanDaysAndSortAllDayFirst() {
        let trip = event("出差", date(7, 8), date(7, 11), allDay: true)
        let meeting = event("周会", date(7, 8, 9), date(7, 8, 10))
        let groups = CalendarViewPlan.agendaGroups([meeting, trip], in: date(7, 1)..<date(8, 1),
                                                   calendar: calendar)
        XCTAssertEqual(groups.map(\.day), [date(7, 8), date(7, 9), date(7, 10)])
        XCTAssertEqual(groups[0].events.map(\.id), ["出差", "周会"])
    }

    // MARK: - 全天行

    func testTimedEventCoveringWholeDayGoesToAllDayRow() {
        let conference = event("大会", date(7, 7, 9), date(7, 9, 18))
        XCTAssertFalse(conference.showsInAllDayRow(on: date(7, 7), calendar: calendar))
        XCTAssertTrue(conference.showsInAllDayRow(on: date(7, 8), calendar: calendar))
        XCTAssertFalse(conference.showsInAllDayRow(on: date(7, 9), calendar: calendar))
    }

    /// 重复事件每次发生的 id 相同,occurrenceKey 必须把它们区分开。
    func testOccurrenceKeyDistinguishesRecurrences() {
        let a = event("例会", date(7, 6, 9), date(7, 6, 10))
        let b = event("例会", date(7, 13, 9), date(7, 13, 10))
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.occurrenceKey, b.occurrenceKey)
    }

    // MARK: - 时间轴排版

    func testNonOverlappingEventsTakeFullWidth() {
        let slots = CalendarTimelineLayout.layout([
            event("A", date(7, 8, 9), date(7, 8, 10)),
            event("B", date(7, 8, 10), date(7, 8, 11)),
        ], on: date(7, 8), calendar: calendar)
        XCTAssertEqual(slots.map(\.columnCount), [1, 1])
        XCTAssertEqual(slots.map(\.column), [0, 0])
        XCTAssertEqual(slots.first?.startMinute, 540)
        XCTAssertEqual(slots.first?.endMinute, 600)
    }

    /// A 9-11 与 B 9:30-10、C 10:30-12 重叠成一组:B 放第二列,C 复用 B 空出来的
    /// 第二列,整组两列。
    func testOverlappingGroupSharesColumnCount() {
        let slots = CalendarTimelineLayout.layout([
            event("A", date(7, 8, 9), date(7, 8, 11)),
            event("B", date(7, 8, 9, 30), date(7, 8, 10)),
            event("C", date(7, 8, 10, 30), date(7, 8, 12)),
        ], on: date(7, 8), calendar: calendar)
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.event.id, $0) })
        XCTAssertEqual(byID["A"]?.column, 0)
        XCTAssertEqual(byID["B"]?.column, 1)
        XCTAssertEqual(byID["C"]?.column, 1)
        XCTAssertEqual(Set(slots.map(\.columnCount)), [2])
    }

    /// 五分钟的短事件按最短显示时长参与重叠判断,紧跟其后的事件不会叠上去。
    func testShortEventsUseMinimumDisplayLength() {
        let slots = CalendarTimelineLayout.layout([
            event("短", date(7, 8, 9), date(7, 8, 9, 5)),
            event("后", date(7, 8, 9, 10), date(7, 8, 9, 40)),
        ], on: date(7, 8), calendar: calendar)
        XCTAssertEqual(Set(slots.map(\.columnCount)), [2])
    }

    /// 跨夜事件在两天里各裁一段;全天事件不进时间轴。
    func testOvernightEventClippedAndAllDayExcluded() {
        let overnight = event("夜车", date(7, 8, 22), date(7, 9, 2))
        let allDay = event("假期", date(7, 8), date(7, 9), allDay: true)
        let first = CalendarTimelineLayout.layout([overnight, allDay], on: date(7, 8), calendar: calendar)
        XCTAssertEqual(first.map(\.event.id), ["夜车"])
        XCTAssertEqual(first.first?.endMinute, 1440)
        let second = CalendarTimelineLayout.layout([overnight], on: date(7, 9), calendar: calendar)
        XCTAssertEqual(second.first?.startMinute, 0)
        XCTAssertEqual(second.first?.endMinute, 120)
    }
}
