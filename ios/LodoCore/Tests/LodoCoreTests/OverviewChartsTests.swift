import XCTest
@testable import LodoCore

final class OverviewChartsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testWeeklyDoneStartsMondayAndFillsZeros() {
        // 2026-07-08 是周三。
        let now = date(2026, 7, 8)
        let done = [date(2026, 7, 6), date(2026, 7, 6, 20), date(2026, 7, 8),
                    date(2026, 7, 5),   // 上周日,不算
                    date(2026, 7, 13)]  // 下周一,不算
        let week = OverviewCharts.weeklyDone(doneDates: done, now: now, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.map(\.count), [2, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(week.first?.date, calendar.startOfDay(for: date(2026, 7, 6)))
        XCTAssertEqual(week.firstIndex { $0.isToday }, 2)
    }

    func testWeeklyDoneOnSundayBelongsToSameWeek() {
        let now = date(2026, 7, 12)  // 周日
        let week = OverviewCharts.weeklyDone(doneDates: [date(2026, 7, 12)], now: now, calendar: calendar)
        XCTAssertEqual(week.last?.count, 1)
        XCTAssertTrue(week.last?.isToday ?? false)
    }

    func testRecentDaysLeavesGapsAsNil() {
        let now = date(2026, 7, 8, 15)
        let values = OverviewCharts.recentDays(
            points: [(date(2026, 7, 8, 0), 3000), (date(2026, 7, 6, 0), 9000)],
            days: 3, now: now, calendar: calendar)
        XCTAssertEqual(values.map(\.value), [9000, nil, 3000])
        XCTAssertEqual(values.map(\.isToday), [false, false, true])
    }

    func testRingProgressAndTaskCompletion() {
        XCTAssertEqual(OverviewCharts.ringProgress(value: 250, goal: 500), 0.5)
        XCTAssertEqual(OverviewCharts.ringProgress(value: 750, goal: 500), 1.5)
        XCTAssertEqual(OverviewCharts.ringProgress(value: nil, goal: 500), 0)
        XCTAssertEqual(OverviewCharts.ringProgress(value: 10, goal: 0), 0)
        XCTAssertNil(OverviewCharts.taskCompletion(done: 0, remaining: 0))
        XCTAssertEqual(OverviewCharts.taskCompletion(done: 1, remaining: 3), 0.25)
    }

    func testRecentWeeksMarksFutureAndOffsets() {
        let now = date(2026, 7, 8)  // 周三
        let done = [date(2026, 6, 22), date(2026, 7, 1), date(2026, 7, 7), date(2026, 7, 9)]
        let days = OverviewCharts.recentWeeks(doneDates: done, weeks: 4, now: now, calendar: calendar)
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days.first?.date, calendar.startOfDay(for: date(2026, 6, 15)))
        XCTAssertEqual(days.first?.weekOffset, -3)
        XCTAssertEqual(days.last?.weekOffset, 0)
        XCTAssertEqual(days.filter(\.isFuture).count, 4)          // 周四到周日
        // 7/9 是本周四,还没到——日期是数据给的,照算(完成时间在未来只会是时钟问题)。
        XCTAssertEqual(days.reduce(0) { $0 + $1.count }, 4)
    }

    func testWeekToDateComparesSamePeriod() {
        let now = date(2026, 7, 8)  // 周三
        let done = [date(2026, 7, 6), date(2026, 7, 8),           // 本周一、三
                    date(2026, 6, 29), date(2026, 7, 1), date(2026, 7, 2)]  // 上周一、三、四
        let result = OverviewCharts.weekToDate(doneDates: done, now: now, calendar: calendar)
        XCTAssertEqual(result.thisWeek, 2)
        XCTAssertEqual(result.lastWeek, 2)  // 上周四不算
    }

    func testBacklogBuckets() {
        let now = date(2026, 7, 8, 15)
        let backlog = OverviewBacklog.build(
            remindAts: [date(2026, 7, 8, 10), date(2026, 7, 6), date(2026, 7, 3),
                        date(2026, 6, 20), date(2026, 7, 8, 18)],  // 最后一件还没到点
            now: now, calendar: calendar)
        XCTAssertEqual(backlog.counts, [1, 1, 1, 1])
        XCTAssertEqual(backlog.oldestDays, 18)
        XCTAssertEqual(backlog.oldestIndex, 3)
        XCTAssertNil(OverviewBacklog.build(remindAts: [], now: now, calendar: calendar).oldestDays)
    }

    func testTodayPlanIgnoresBacklog() {
        let now = date(2026, 7, 8, 15)
        let plan = OverviewCharts.todayPlan(
            doneToday: 2, pendingRemindAts: [date(2026, 7, 8, 18), date(2026, 7, 5), date(2026, 7, 9)],
            now: now, calendar: calendar)
        XCTAssertEqual(plan.done, 2)
        XCTAssertEqual(plan.remaining, 1)
    }

    func testNextHoursAlignsTemperatureAndAQI() {
        let now = date(2026, 7, 8, 9).addingTimeInterval(20 * 60)
        let points = OverviewCharts.nextHours(
            temperatures: [(date(2026, 7, 8, 9), 20), (date(2026, 7, 8, 10), 22)],
            aqi: [(date(2026, 7, 8, 10), 80), (date(2026, 7, 8, 11), 120)],
            now: now, hours: 3, calendar: calendar)
        XCTAssertEqual(points.map(\.temperature), [20, 22, nil])
        XCTAssertEqual(points.map(\.aqi), [nil, 80, 120])
        XCTAssertTrue(OverviewCharts.nextHours(temperatures: [], aqi: [], now: now, calendar: calendar).isEmpty)
    }

    func testFingerprintIsStableAndSensitive() {
        XCTAssertEqual(OverviewCharts.fingerprint(["a", "b"]), OverviewCharts.fingerprint(["a", "b"]))
        XCTAssertNotEqual(OverviewCharts.fingerprint(["a", "b"]), OverviewCharts.fingerprint(["ab"]))
    }

    func testPercentTextDoesNotCap() {
        XCTAssertEqual(OverviewCharts.percentText(2.5), "250%")
        XCTAssertEqual(OverviewCharts.percentText(0.333), "33%")
    }
}
