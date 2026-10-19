import XCTest
@testable import LodoCore

/// 出血量按天归并的离线单测。
final class CycleFlowTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    func testManualBeatsHealthAndLatestWins() {
        let older = CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "light", updatedAt: t0)
        let newer = CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "heavy", updatedAt: t0.addingTimeInterval(60))
        let days = CycleFlow.resolve(
            manual: [older, newer],
            health: [CycleFlow.HealthSample(dayKey: "2026-07-02", level: .medium),
                     CycleFlow.HealthSample(dayKey: "2026-07-03", level: .light)])
        XCTAssertEqual(days["2026-07-02"]?.level, .heavy)
        XCTAssertEqual(days["2026-07-02"]?.source, .manual)
        XCTAssertEqual(days["2026-07-03"]?.source, .health)
        XCTAssertNil(days["2026-07-04"])                      // 没记就是没有,不是「无」
    }

    func testTombstoneRevealsHealthAndBeatsOlderCopy() {
        let copy = CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "light", updatedAt: t0)
        let cleared = CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "light",
                                            updatedAt: t0.addingTimeInterval(5), isDeleted: true)
        let onlyManual = CycleFlow.resolve(manual: [copy, cleared], health: [])
        XCTAssertNil(onlyManual["2026-07-02"])
        let withHealth = CycleFlow.resolve(manual: [copy, cleared],
                                           health: [CycleFlow.HealthSample(dayKey: "2026-07-02", level: .medium)])
        XCTAssertEqual(withHealth["2026-07-02"]?.level, .medium)
    }

    func testHealthSamplesSameDay() {
        let key = "2026-07-02"
        func level(_ levels: [CycleFlowLevel]) -> CycleFlowLevel? {
            CycleFlow.resolve(manual: [], health: levels.map { CycleFlow.HealthSample(dayKey: key, level: $0) })[key]?.level
        }
        XCTAssertEqual(level([.light, .heavy, .unspecified]), .heavy)
        XCTAssertEqual(level([.unspecified, .none]), .unspecified)
        XCTAssertEqual(level([.none, .none]), CycleFlowLevel.none)
    }

    func testUnknownStoredLevelKeptRaw() {
        let day = CycleFlow.resolve(
            manual: [CycleFlow.ManualEntry(dayKey: "2026-07-02", levelRaw: "spotting", updatedAt: t0)],
            health: [])["2026-07-02"]
        XCTAssertNil(day?.level)
        XCTAssertEqual(day?.raw, "spotting")
    }

    func testDayKeys() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 27))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!
        XCTAssertEqual(CycleFlow.dayKeys(from: start, through: end, calendar: calendar),
                       ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
        XCTAssertEqual(CycleFlow.date(fromKey: "2026-03-01", calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        XCTAssertNil(CycleFlow.date(fromKey: "2026-02-30", calendar: calendar))
        XCTAssertNil(CycleFlow.date(fromKey: "bad", calendar: calendar))
    }
}

extension CycleFlowTests {
    func testDayKeyIsGregorianEvenWithOtherCalendars() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 2))!
        XCTAssertEqual(CycleFlow.dayKey(date, calendar: buddhist), "2026-07-02")
        XCTAssertEqual(CycleFlow.date(fromKey: "2026-07-02", calendar: buddhist), date)
        XCTAssertNil(CycleFlow.date(fromKey: "2026-7-2", calendar: calendar))
        XCTAssertNil(CycleFlow.date(fromKey: "2026-13-01", calendar: calendar))
    }

    func testHealthConflictFlagged() {
        let key = "2026-07-02"
        let day = CycleFlow.resolve(manual: [], health: [CycleFlow.HealthSample(dayKey: key, level: .none),
                                                        CycleFlow.HealthSample(dayKey: key, level: .light)])[key]
        XCTAssertEqual(day?.level, .light)
        XCTAssertEqual(day?.conflict, true)
    }
}

