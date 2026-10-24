import XCTest
@testable import LodoCore

/// 手记经期写回健康 App 的对账逻辑。
final class CycleHealthExportTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ key: String) -> Date { CycleFlow.date(fromKey: key, calendar: calendar)! }
    private func period(_ start: String, _ end: String?) -> CyclePlan.Period {
        CyclePlan.Period(start: day(start), end: end.map(day), source: .manual(UUID()))
    }

    private func desired(_ periods: [CyclePlan.Period], flows: [CycleFlow.ManualEntry] = [],
                         foreign: Set<String> = [], today: String = "2026-07-20",
                         since: String = "2026-01-01", openLimit: Int = 5) -> [String: CycleHealthExport.Day] {
        CycleHealthExport.desired(manual: periods, flows: flows, foreignDays: foreign, since: day(since),
                                  today: day(today), openLimit: openLimit, calendar: calendar)
    }

    func testClosedPeriodWritesEveryDayWithStartFlagAndLevels() {
        let flows = [CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "heavy", updatedAt: Date()),
                     CycleFlow.ManualEntry(dayKey: "2026-07-03", levelRaw: "light", updatedAt: Date(), isDeleted: true),
                     // 经期外的出血量不写
                     CycleFlow.ManualEntry(dayKey: "2026-07-10", levelRaw: "light", updatedAt: Date())]
        let result = desired([period("2026-07-01", "2026-07-04")], flows: flows)
        XCTAssertEqual(result.keys.sorted(), ["2026-07-01", "2026-07-02", "2026-07-03", "2026-07-04"])
        XCTAssertEqual(result["2026-07-01"]?.isStart, true)
        XCTAssertEqual(result["2026-07-02"]?.isStart, false)
        XCTAssertEqual(result["2026-07-02"]?.level, .heavy)
        XCTAssertEqual(result["2026-07-03"]?.level, .unspecified)   // 墓碑 = 没记
        XCTAssertNil(result["2026-07-10"])
    }

    func testOpenPeriodStopsAtTodayAndTypicalLength() {
        XCTAssertEqual(desired([period("2026-07-18", nil)]).keys.sorted(),
                       ["2026-07-18", "2026-07-19", "2026-07-20"])
        XCTAssertEqual(desired([period("2026-07-01", nil)], openLimit: 5).count, 5)
        XCTAssertTrue(desired([period("2026-07-25", "2026-07-27")]).isEmpty)   // 未来的不写
    }

    func testSkipsDaysOtherSourcesRecordedAndOutsideWindow() {
        let result = desired([period("2026-07-01", "2026-07-03")], foreign: ["2026-07-02"], since: "2026-07-03")
        XCTAssertEqual(result.keys.sorted(), ["2026-07-03"])
        XCTAssertEqual(result["2026-07-03"]?.isStart, false)
    }

    func testPlanKeepsMatchingDeletesExtrasAndAdds() {
        let a = CycleHealthExport.Day(dayKey: "2026-07-01", level: .unspecified, isStart: true)
        let b = CycleHealthExport.Day(dayKey: "2026-07-02", level: .heavy, isStart: false)
        let c = CycleHealthExport.Day(dayKey: "2026-07-03", level: .light, isStart: false)
        let keep = UUID(), dup = UUID(), stale = UUID(), gone = UUID()
        let existing = [
            CycleHealthExport.Existing(id: keep, day: a),
            CycleHealthExport.Existing(id: dup, day: a),                              // 两台设备各写一条
            CycleHealthExport.Existing(id: stale, day: .init(dayKey: "2026-07-02", level: .light, isStart: false)),
            CycleHealthExport.Existing(id: gone, day: .init(dayKey: "2026-06-01", level: .medium, isStart: true)),
        ]
        let plan = CycleHealthExport.plan(desired: [a.dayKey: a, b.dayKey: b, c.dayKey: c], existing: existing)
        XCTAssertEqual(Set(plan.delete), [dup, stale, gone])
        XCTAssertEqual(plan.add, [b, c])
        let ids = [keep, dup].sorted { $0.uuidString < $1.uuidString }
        XCTAssertFalse(plan.delete.contains(ids[0]))

        XCTAssertTrue(CycleHealthExport.plan(desired: [a.dayKey: a],
                                             existing: [.init(id: keep, day: a)]).isEmpty)
    }
}
