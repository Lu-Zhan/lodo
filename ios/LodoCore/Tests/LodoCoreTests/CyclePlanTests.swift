import XCTest
@testable import LodoCore

final class CyclePlanTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ month: Int, _ d: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour))!
    }

    private func manual(_ start: Date, _ end: Date?) -> CyclePlan.Period {
        CyclePlan.Period(start: start, end: end, source: .manual(UUID()))
    }

    func testFlowDaysGroupIntoPeriodsAllowingOneMissingDay() {
        let days = [day(7, 1, hour: 9), day(7, 2), day(7, 4), day(7, 29), day(7, 30)]
        let periods = CyclePlan.periods(fromFlowDays: days, calendar: calendar)
        XCTAssertEqual(periods.map(\.start), [day(7, 1), day(7, 29)])
        XCTAssertEqual(periods.map(\.end), [day(7, 4), day(7, 30)])
    }

    func testManualWinsOverOverlappingHealthPeriod() {
        let health = CyclePlan.periods(fromFlowDays: [day(8, 2), day(8, 3), day(9, 1)], calendar: calendar)
        let merged = CyclePlan.merge(manual: [manual(day(8, 1), day(8, 5))], health: health,
                                     today: day(10, 1), calendar: calendar)
        XCTAssertEqual(merged.map(\.start), [day(8, 1), day(9, 1)])
        XCTAssertEqual(merged.map(\.fromHealth), [false, true])
    }

    func testAveragesAndPrediction() {
        let periods = [manual(day(7, 1), day(7, 5)), manual(day(7, 29), day(8, 2)),
                       manual(day(8, 28), day(9, 1))]
        let s = CyclePlan.summary(periods, today: day(9, 10), calendar: calendar)
        XCTAssertEqual(s.averageCycle, 29)   // 28、30
        XCTAssertEqual(s.averagePeriod, 5)
        XCTAssertNil(s.variation)            // 只有两个周期
        XCTAssertEqual(s.nextStart, day(9, 26))
        XCTAssertEqual(s.daysUntilNext, 16)
        XCTAssertEqual(s.cycleDay, 14)
        XCTAssertNil(s.periodDay)
        XCTAssertFalse(s.estimatedFromDefault)
        XCTAssertEqual(s.cycles.map(\.length), [30, 28])
    }

    func testOngoingManualPeriodCountsDays() {
        let s = CyclePlan.summary([manual(day(10, 1), nil)], today: day(10, 3, hour: 15), calendar: calendar)
        XCTAssertEqual(s.periodDay, 3)
        XCTAssertTrue(s.estimatedFromDefault)
        XCTAssertEqual(s.nextStart, day(10, 29))
    }

    func testForgottenOpenPeriodEndsByItself() {
        let s = CyclePlan.summary([manual(day(9, 1), nil)], today: day(9, 20), calendar: calendar)
        XCTAssertNil(s.periodDay)
    }

    func testImplausibleCyclesAreIgnored() {
        let periods = [manual(day(5, 1), day(5, 5)), manual(day(7, 25), day(7, 29)),  // 85 天:漏记
                       manual(day(8, 22), day(8, 26))]
        let s = CyclePlan.summary(periods, today: day(9, 1), calendar: calendar)
        XCTAssertEqual(s.averageCycle, 28)
    }

    func testOverduePredictionIsNegative() {
        let periods = [manual(day(8, 1), day(8, 5)), manual(day(8, 29), day(9, 2))]
        let s = CyclePlan.summary(periods, today: day(9, 30), calendar: calendar)
        XCTAssertEqual(s.daysUntilNext, -4)   // 预计 9/26
    }

    func testReminderOnlyForReliablePrediction() {
        let periods = [manual(day(8, 1), day(8, 5)), manual(day(8, 29), day(9, 2))]
        let s = CyclePlan.summary(periods, today: day(9, 10), calendar: calendar)
        let fire = CyclePlan.reminderDate(s, daysBefore: 2, time: "09:00", now: day(9, 10), calendar: calendar)
        XCTAssertEqual(fire, day(9, 24, hour: 9))
        let single = CyclePlan.summary([manual(day(9, 1), day(9, 5))], today: day(9, 10), calendar: calendar)
        XCTAssertNil(CyclePlan.reminderDate(single, daysBefore: 2, time: "09:00", now: day(9, 10),
                                            calendar: calendar))
    }

    func testDefaultFollowsSex() {
        XCTAssertTrue(CyclePlan.isEnabled(.auto, sex: .female))
        XCTAssertFalse(CyclePlan.isEnabled(.auto, sex: .male))
        XCTAssertFalse(CyclePlan.isEnabled(.auto, sex: .unknown))
        XCTAssertTrue(CyclePlan.isEnabled(.on, sex: .male))
        XCTAssertFalse(CyclePlan.isEnabled(.off, sex: .female))
    }

    func testForgottenOpenRecordNoLongerBlocksNewStart() {
        XCTAssertTrue(CyclePlan.isOpen(start: day(10, 1), end: nil, today: day(10, 5), calendar: calendar))
        XCTAssertFalse(CyclePlan.isOpen(start: day(9, 1), end: nil, today: day(9, 30), calendar: calendar))
        XCTAssertFalse(CyclePlan.isOpen(start: day(10, 1), end: day(10, 3), today: day(10, 2), calendar: calendar))
    }

    func testReminderStillScheduledDuringPeriod() {
        // 经期最后一天点了「结束了」:下一次的提醒照样排(不用等出了经期再进健康页)。
        let periods = [manual(day(8, 1), day(8, 5)), manual(day(8, 29), day(9, 2))]
        let s = CyclePlan.summary(periods, today: day(9, 2, hour: 20), calendar: calendar)
        XCTAssertNotNil(s.periodDay)
        XCTAssertEqual(CyclePlan.reminderDate(s, daysBefore: 2, time: "09:00", now: day(9, 2, hour: 20),
                                              calendar: calendar), day(9, 24, hour: 9))
    }
}
