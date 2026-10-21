import XCTest
@testable import LodoCore

final class WatchTodayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }
    private var now: Date { date(8, 9) }

    private func task(remindAt: Date, now: Date? = nil) -> Bool {
        WatchToday.includesTask(isInbox: false, createdAt: date(1, 9), remindAt: remindAt,
                                now: now ?? self.now, calendar: calendar)
    }

    func testDueLaterTodayIncluded() {
        XCTAssertTrue(task(remindAt: date(8, 23, 59)))
    }

    func testTomorrowExcluded() {
        XCTAssertFalse(task(remindAt: date(9, 0)))
    }

    func testOverdueIncluded() {
        XCTAssertTrue(task(remindAt: date(6, 20)))
    }

    /// 23:50 时还在纠缠的逾期事项不会因为下一次提醒排到了明天就消失(判据不看 nextRemindAt)。
    func testLateNightOverdueStaysUntilMidnight() {
        XCTAssertTrue(task(remindAt: date(7, 20), now: date(8, 23, 50)))
    }

    /// 重复事项今天这次完成后 remindAt 顺延到明天,首页不再显示。
    func testRecurringAdvancedToTomorrowExcluded() {
        XCTAssertFalse(task(remindAt: date(9, 7), now: date(8, 22)))
    }

    func testInboxByCreationDay() {
        XCTAssertTrue(WatchToday.includesTask(isInbox: true, createdAt: date(8, 0), remindAt: .distantFuture,
                                              now: now, calendar: calendar))
        XCTAssertFalse(WatchToday.includesTask(isInbox: true, createdAt: date(7, 23, 59), remindAt: .distantFuture,
                                               now: now, calendar: calendar))
    }

    func testMemoryToday() {
        XCTAssertTrue(WatchToday.includesMemory(createdAt: date(8, 0), tags: [], now: now, calendar: calendar))
        XCTAssertTrue(WatchToday.includesMemory(createdAt: date(8, 8), tags: ["AI记录", "旅行", "菜单"],
                                                now: now, calendar: calendar))
        XCTAssertFalse(WatchToday.includesMemory(createdAt: date(7, 23, 59), tags: [], now: now, calendar: calendar))
    }

    func testMemoryExcludedTags() {
        for tag in ["人脉", "资产", "健康", "体检报告", "体重秤报告"] {
            XCTAssertFalse(WatchToday.includesMemory(createdAt: date(8, 8), tags: [tag], now: now, calendar: calendar),
                           tag)
        }
    }

    func testNextDayStart() {
        XCTAssertEqual(WatchToday.nextDayStart(after: date(8, 23, 59), calendar: calendar), date(9, 0))
    }
}
