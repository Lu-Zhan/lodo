import XCTest
@testable import LodoCore

/// ParsedTask.caption 离线单测——AI 助手对话里内联事项卡片的展示文案。
final class ParsedTaskTests: XCTestCase {
    private func makeDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = hour; components.minute = minute
        return Calendar.current.date(from: components)!
    }

    func testCaptionPlainNoRepeat() {
        let parsed = ParsedTask(title: "开会", remindAt: makeDate(hour: 15, minute: 0),
                                allDay: false, repeatType: .none,
                                repeatDays: [], repeatTimes: [])
        XCTAssertTrue(parsed.caption.contains("15:00"))
        XCTAssertFalse(parsed.caption.contains("·"))
    }

    func testCaptionAllDay() {
        let parsed = ParsedTask(title: "生日", remindAt: makeDate(hour: 9, minute: 0),
                                allDay: true, repeatType: .none,
                                repeatDays: [], repeatTimes: [])
        XCTAssertTrue(parsed.caption.contains("全天"))
    }

    func testCaptionDailyRepeat() {
        let parsed = ParsedTask(title: "喝水", remindAt: makeDate(hour: 9, minute: 0),
                                allDay: false, repeatType: .daily,
                                repeatDays: [], repeatTimes: ["09:00", "21:00"])
        XCTAssertTrue(parsed.caption.contains("每天 09:00/21:00"))
    }

    func testCaptionWeeklyRepeatUsesWeekdayNames() {
        let parsed = ParsedTask(title: "开周会", remindAt: makeDate(hour: 11, minute: 0),
                                allDay: false, repeatType: .weekly,
                                repeatDays: [2], repeatTimes: ["11:00"])
        XCTAssertTrue(parsed.caption.contains("每周三 11:00"))
    }
}
