import XCTest
@testable import LodoCore

final class AssetTrendTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func point(_ date: Date, _ value: Double?, currency: String = "CNY") -> AssetValuePoint {
        AssetValuePoint(date: date, value: value, liability: nil, currency: currency)
    }

    private let noRates: (Double, String, String) -> Double? = { _, _, _ in nil }

    func testAppendingReplacesSameDay() {
        var points = AssetHistory.appending(point(date(2026, 7, 1), 100), to: [], calendar: calendar)
        points = AssetHistory.appending(point(date(2026, 7, 1).addingTimeInterval(3600), 120),
                                        to: points, calendar: calendar)
        points = AssetHistory.appending(point(date(2026, 8, 1), 150), to: points, calendar: calendar)
        XCTAssertEqual(points.map(\.value), [120, 150])
        XCTAssertEqual(AssetHistory.decode(AssetHistory.encode(points)), points)
    }

    func testEffectiveAddsCurrentWhenOutOfSync() {
        let old = [point(date(2026, 5, 1), 100)]
        XCTAssertEqual(AssetHistory.effective(old, current: point(date(2026, 5, 1), 100)).count, 1)
        let synced = AssetHistory.effective(old, current: point(date(2026, 9, 1), 200))
        XCTAssertEqual(synced.map(\.value), [100, 200])
        XCTAssertEqual(AssetHistory.effective([], current: point(date(2026, 9, 1), 50)).map(\.value), [50])
    }

    func testTrendUsesFilledDatesAndProjects() {
        let now = date(2026, 10, 15)
        let house = [point(date(2026, 1, 1), 1000), point(date(2026, 8, 1), 1200)]
        let cash = [point(date(2026, 6, 1), 300)]
        let trend = AssetTrend.build(assets: [house, cash], monthlyNet: 50, in: "CNY", now: now,
                                     calendar: calendar, convert: noRates)
        // 起点(4/15):只有房子 1000;6/1 存款进来;8/1 房子涨到 1200;现在。
        XCTAssertEqual(trend.history.map(\.total), [1000, 1300, 1500, 1500])
        XCTAssertEqual(trend.history.first?.date, calendar.date(byAdding: .month, value: -6, to: now))
        XCTAssertEqual(trend.projection.count, 7)
        XCTAssertEqual(trend.projection.first?.total, 1500)
        XCTAssertEqual(trend.projection.last?.total, 1800)
        XCTAssertFalse(trend.needsUpdate)
    }

    func testTrendMergesSameDayPoints() {
        let now = date(2026, 10, 15)
        let a = [point(date(2026, 8, 1), 100)]
        let b = [point(date(2026, 8, 1).addingTimeInterval(60), 50)]
        let c = [point(now.addingTimeInterval(-60), 10)]
        let trend = AssetTrend.build(assets: [a, b, c], monthlyNet: 0, in: "CNY", now: now,
                                     calendar: calendar, convert: noRates)
        // 8/1 两项合成一个点;今天填的并进"现在"那个点。
        XCTAssertEqual(trend.history.map(\.total), [150, 160])
    }

    func testTrendFlatWhenNotUpdatedForSixMonths() {
        let now = date(2026, 10, 15)
        let trend = AssetTrend.build(assets: [[point(date(2025, 12, 1), 800)]], monthlyNet: 0,
                                     in: "CNY", now: now, calendar: calendar, convert: noRates)
        XCTAssertEqual(trend.history.map(\.total), [800, 800])
        XCTAssertTrue(trend.needsUpdate)
        XCTAssertEqual(trend.lastUpdate, date(2025, 12, 1))
    }

    func testTrendReportsMissingCurrency() {
        let trend = AssetTrend.build(assets: [[point(date(2026, 9, 1), 10, currency: "JPY")]],
                                     monthlyNet: 0, in: "CNY", now: date(2026, 10, 15),
                                     calendar: calendar, convert: noRates)
        XCTAssertEqual(trend.missingCurrencies, ["JPY"])
        XCTAssertTrue(AssetTrend.build(assets: [], monthlyNet: 0, in: "CNY", now: .now,
                                       convert: noRates).isEmpty)
    }

    func testCompositionMergesAndSorts() {
        let result = FinancePlan.composition(
            [("存款", 100, "CNY"), ("房产", 500, "CNY"), ("存款", 50, "CNY"), ("其他", 0, "CNY"),
             ("投资", 10, "USD")],
            in: "CNY") { amount, _, _ in amount * 7 }
        XCTAssertEqual(result.slices.map(\.name), ["房产", "存款", "投资"])
        XCTAssertEqual(result.slices.map(\.amount), [500, 150, 70])
        XCTAssertEqual(result.total, 720)
    }

    func testEstimatedSpendingCountsMonthly() {
        let entries = [
            FinanceSnapshot(kind: .income, title: "工资", amount: 10_000),
            FinanceSnapshot(kind: .expense, title: "房贷", amount: 3_000),
            FinanceSnapshot(kind: .expense, title: "日常", amount: 2_000, cadence: .yearly, estimated: true),
        ]
        let total = FinancePlan.monthlyTotal(entries, in: "CNY", now: .now, convert: noRates)
        XCTAssertEqual(total.expense, 3_000)
        XCTAssertEqual(total.spending, 2_000)
        XCTAssertEqual(total.net, 5_000)
        XCTAssertEqual(FinancePlan.monthlyAmount(entries[2]), 2_000)
    }

    func testProvidentFundIsPreset() {
        XCTAssertEqual(AssetCategory.orderedGroups(["其他", "公积金", "房产"]), ["房产", "公积金", "其他"])
    }
}
