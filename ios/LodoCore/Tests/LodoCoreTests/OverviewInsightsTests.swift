import XCTest
@testable import LodoCore

final class OverviewInsightsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 时间轴

    func testTimelineDefaultsAndExpands() {
        let day = date(2026, 7, 8)
        let plain = OverviewTimeline.make(day: day, busy: [], points: [], calendar: calendar)
        XCTAssertEqual(plain.start, date(2026, 7, 8, 8))
        XCTAssertEqual(plain.end, date(2026, 7, 8, 22))
        let wide = OverviewTimeline.make(
            day: day, busy: [DateInterval(start: date(2026, 7, 8, 7, 30), end: date(2026, 7, 8, 9))],
            points: [date(2026, 7, 8, 22, 15)], calendar: calendar)
        XCTAssertEqual(wide.start, date(2026, 7, 8, 7))
        XCTAssertEqual(wide.end, date(2026, 7, 8, 23))
        XCTAssertEqual(plain.fraction(date(2026, 7, 8, 15)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(plain.fraction(date(2026, 7, 8, 3)), 0)
    }

    func testFreeSlotsMergeOverlaps() {
        let busy = [DateInterval(start: date(2026, 7, 8, 10), end: date(2026, 7, 8, 11)),
                    DateInterval(start: date(2026, 7, 8, 10, 30), end: date(2026, 7, 8, 12)),
                    DateInterval(start: date(2026, 7, 8, 12, 20), end: date(2026, 7, 8, 13))]
        let slots = OverviewTimeline.freeSlots(busy: busy, from: date(2026, 7, 8, 9),
                                               to: date(2026, 7, 8, 18))
        // 9–10 空;12:00–12:20 只有 20 分钟不算;13–18 空。
        XCTAssertEqual(slots, [DateInterval(start: date(2026, 7, 8, 9), end: date(2026, 7, 8, 10)),
                               DateInterval(start: date(2026, 7, 8, 13), end: date(2026, 7, 8, 18))])
        XCTAssertTrue(OverviewTimeline.freeSlots(busy: [], from: date(2026, 7, 8, 18),
                                                 to: date(2026, 7, 8, 9)).isEmpty)
    }

    // MARK: - 旅行中

    func testTripOngoingDayAndNext() {
        let now = date(2026, 7, 8, 12)
        let place = TravelEntry(id: UUID(), kind: .place, title: "清水寺", start: date(2026, 7, 8, 15))
        let morning = TravelEntry(id: UUID(), kind: .place, title: "伏见稻荷", start: date(2026, 7, 8, 9))
        let hotel = TravelEntry(id: UUID(), kind: .lodging, title: "京都酒店",
                                start: date(2026, 7, 7, 15), end: date(2026, 7, 10, 11))
        let status = OverviewTripStatus.build(
            trips: [(date(2026, 8, 1), date(2026, 8, 3)), (date(2026, 7, 7), date(2026, 7, 10))],
            entries: [[], [place, morning, hotel]], now: now, calendar: calendar)
        XCTAssertEqual(status?.tripIndex, 1)
        XCTAssertEqual(status?.phase, .ongoing(day: 2, of: 4))
        XCTAssertEqual(status?.next?.title, "清水寺")
        XCTAssertEqual(status?.today.map(\.title), ["伏见稻荷", "清水寺"])
        XCTAssertEqual(status?.tonight?.title, "京都酒店")
    }

    func testTripUpcomingWithinHorizon() {
        let now = date(2026, 7, 8)
        let status = OverviewTripStatus.build(
            trips: [(date(2026, 7, 20), date(2026, 7, 22)), (date(2026, 7, 12), date(2026, 7, 13))],
            entries: [[], []], now: now, calendar: calendar)
        XCTAssertEqual(status?.tripIndex, 1)
        XCTAssertEqual(status?.phase, .upcoming(daysUntil: 4))
        XCTAssertNil(OverviewTripStatus.build(trips: [(date(2026, 12, 1), date(2026, 12, 2))],
                                              entries: [[]], now: now, calendar: calendar))
    }

    // MARK: - 例行状态

    func testRoutineStatusDays() {
        let now = date(2026, 7, 8, 12)
        let a = UUID(), b = UUID()
        let status = OverviewRoutineStatus.build(
            routines: [(a, "新闻简报", true, date(2026, 7, 9, 8)),
                       (b, "周报", false, date(2026, 7, 8, 18))],
            runs: [(a, true, date(2026, 7, 8, 8)),           // 今天先失败
                   (a, false, date(2026, 7, 8, 9)),          // 后成功
                   (a, true, date(2026, 7, 7, 8)),           // 昨天只失败
                   (a, false, date(2026, 6, 20, 8))],        // 窗口外
            now: now, calendar: calendar)
        XCTAssertEqual(status.rows[0].days.suffix(2), [.failed, .success])
        XCTAssertEqual(status.rows[0].days.count, 7)
        XCTAssertEqual(status.failures, 2)
        XCTAssertNil(status.rows[1].nextRun)  // 停用的不算下一次
        XCTAssertEqual(status.nextRun?.id, a)
    }
}
