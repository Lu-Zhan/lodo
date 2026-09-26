import XCTest
@testable import LodoCore

/// 总览页 widget 布局与时间小计算的纯逻辑单测。基准时间 2026-07-08 09:00(周三)。
final class OverviewLayoutTests: XCTestCase {
    let calendar = Calendar.current
    var t0: Date { date(7, 8, 9) }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                      year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: - 布局存取

    func testDefaultLayoutContainsEveryKindOnce() {
        let kinds = OverviewLayout.default.items.map(\.kind)
        XCTAssertEqual(Set(kinds), Set(OverviewWidgetKind.allCases))
        XCTAssertEqual(kinds.count, OverviewWidgetKind.allCases.count)
    }

    func testRoundTrip() {
        var layout = OverviewLayout.default
        layout.items[0].isVisible = false
        layout.items[1].size = .large
        layout.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(OverviewLayout.decode(layout.encoded()), layout)
    }

    func testDecodeGarbageFallsBackToDefault() {
        XCTAssertEqual(OverviewLayout.decode(nil), .default)
        XCTAssertEqual(OverviewLayout.decode("not json"), .default)
    }

    /// 老布局里没有的种类补在末尾并显示;认不出的种类丢掉;重复的只留第一个;
    /// 不允许的尺寸改回默认。
    func testDecodeMergesUnknownMissingAndInvalid() {
        let stored = """
        [{"kind":"health","size":"large","isVisible":false},
         {"kind":"weather","size":"small"},
         {"kind":"health","size":"large","isVisible":true},
         {"kind":"clock","size":"large"}]
        """
        let layout = OverviewLayout.decode(stored)
        XCTAssertEqual(layout.items.first?.kind, .health)
        XCTAssertEqual(layout.items.first?.isVisible, false)
        XCTAssertEqual(layout.items[1].kind, .clock)
        XCTAssertEqual(layout.items[1].size, .small)
        XCTAssertEqual(layout.items.count, OverviewWidgetKind.allCases.count)
        XCTAssertTrue(layout.items.dropFirst(2).allSatisfy(\.isVisible))
    }

    func testMoveMatchesArraySemantics() {
        var layout = OverviewLayout.default
        let original = layout.items.map(\.kind)
        layout.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        XCTAssertEqual(layout.items.map(\.kind),
                       Array(original[2..<4]) + Array(original[0..<2]) + Array(original[4...]))
        layout.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)
        XCTAssertEqual(layout.items.first?.kind, original[5])
    }

    // MARK: - 两列排版

    func testRowsPairSmallsAndKeepOrder() {
        let layout = OverviewLayout(items: [
            .init(kind: .clock), .init(kind: .nextUp),          // 两小并排
            .init(kind: .countdown),                              // 小卡后接大卡:独占半行
            .init(kind: .due),
            .init(kind: .today, isVisible: false),                // 隐藏的不排
            .init(kind: .agenda, size: .small),                   // 最后一张小卡
        ])
        let rows = layout.rows().map { $0.map(\.kind) }
        XCTAssertEqual(rows, [[.clock, .nextUp], [.countdown], [.due], [.agenda]])
    }

    // MARK: - 时间

    func testDayProgress() {
        XCTAssertEqual(OverviewTime.dayProgress(at: date(7, 8, 12), calendar: calendar), 0.5, accuracy: 0.001)
    }

    func testRelativeLabel() {
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 8, 9, 30), from: t0, calendar: calendar), "30 分钟后")
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 8, 11), from: t0, calendar: calendar), "2 小时后")
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 8, 11, 15), from: t0, calendar: calendar), "2 小时 15 分钟后")
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 9, 8), from: t0, calendar: calendar), "明天")
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 12, 8), from: t0, calendar: calendar), "4 天后")
        XCTAssertEqual(OverviewTime.relativeLabel(to: date(7, 8, 8), from: t0, calendar: calendar), "已开始")
    }

    func testNextBirthday() {
        // 今年还没过
        XCTAssertEqual(OverviewTime.nextBirthday(date(9, 1, year: 1990), after: t0, calendar: calendar), date(9, 1))
        // 今年已过 → 明年
        XCTAssertEqual(OverviewTime.nextBirthday(date(3, 1, year: 1990), after: t0, calendar: calendar),
                       date(3, 1, year: 2027))
        // 今天就是生日
        XCTAssertEqual(OverviewTime.nextBirthday(date(7, 8, year: 1990), after: t0, calendar: calendar), date(7, 8))
        // 2/29 在非闰年落到 2/28
        XCTAssertEqual(OverviewTime.nextBirthday(date(2, 29, year: 2000), after: t0, calendar: calendar),
                       date(2, 28, year: 2027))
    }

    func testCountdownEntries() {
        let entries = OverviewCountdownEntry.build(
            trips: [("a", "京都", date(7, 20), date(7, 23)),
                    ("b", "进行中", date(7, 5), date(7, 10)),
                    ("c", "已结束", date(6, 1), date(6, 3)),
                    ("d", "太远", date(12, 1), date(12, 5))],
            birthdays: [("p", "妈妈", date(7, 15, year: 1960)),
                        ("q", "远的", date(1, 15, year: 1990))],
            now: t0, calendar: calendar)
        XCTAssertEqual(entries.map(\.title), ["进行中", "妈妈", "京都"])
        XCTAssertEqual(entries.map(\.kind), [.trip, .birthday, .trip])
    }
}
