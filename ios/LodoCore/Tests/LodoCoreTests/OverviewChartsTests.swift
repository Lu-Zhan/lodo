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
}
