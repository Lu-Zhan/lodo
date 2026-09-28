import XCTest
@testable import LodoCore

final class FinancePlanTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testMonthlyTotalFoldsCadenceAndSkipsIrregularAndEnded() {
        let now = date(2026, 7, 8, 9)
        let entries = [
            FinanceSnapshot(kind: .income, title: "工资", amount: 20000),
            FinanceSnapshot(kind: .income, title: "年终奖", amount: 60000, cadence: .yearly),
            FinanceSnapshot(kind: .income, title: "项目奖", amount: 5000, cadence: .irregular),
            FinanceSnapshot(kind: .expense, title: "房贷", amount: 8000),
            FinanceSnapshot(kind: .expense, title: "车贷", amount: 3000, endDate: date(2026, 1, 1)),
            FinanceSnapshot(kind: .expense, title: "美元订阅", amount: 10, currency: "USD"),
            FinanceSnapshot(kind: .creditCard, title: "招行", amount: 50000, dayOfMonth: 5),
        ]
        let total = FinancePlan.monthlyTotal(entries, in: "CNY", now: now) { _, _, _ in nil }
        XCTAssertEqual(total.income, 25000, accuracy: 0.001)
        XCTAssertEqual(total.expense, 8000, accuracy: 0.001)
        XCTAssertEqual(total.net, 17000, accuracy: 0.001)
        XCTAssertEqual(total.irregularCount, 1)
        XCTAssertEqual(total.missingCurrencies, ["USD"])
    }

    func testNextDateClampsToMonthEnd() {
        XCTAssertEqual(FinancePlan.nextDate(day: 31, onOrAfter: date(2027, 2, 3), calendar: calendar),
                       date(2027, 2, 28))
        XCTAssertEqual(FinancePlan.nextDate(day: 5, onOrAfter: date(2026, 7, 8), calendar: calendar),
                       date(2026, 8, 5))
        XCTAssertEqual(FinancePlan.nextDate(day: 8, onOrAfter: date(2026, 7, 8, 15), calendar: calendar),
                       date(2026, 7, 8))
    }

    func testReminderIsDayBeforeDueAtAllDayTime() {
        let card = FinanceSnapshot(kind: .creditCard, title: "招行", dayOfMonth: 20, statementDay: 3)
        let r = FinancePlan.reminder(for: card, allDayTime: "09:00", now: date(2026, 7, 8, 9),
                                     calendar: calendar)
        XCTAssertEqual(r?.dueDate, date(2026, 7, 20))
        XCTAssertEqual(r?.remindAt, date(2026, 7, 19, 9))
        XCTAssertEqual(r?.cycle, "2026-07-20")
        XCTAssertEqual(FinancePlan.nextStatementDate(card, now: date(2026, 7, 8), calendar: calendar),
                       date(2026, 8, 3))
    }

    func testReminderInThePastFiresNow() {
        let card = FinanceSnapshot(kind: .creditCard, title: "招行", dayOfMonth: 9)
        let now = date(2026, 7, 8, 20)
        let r = FinancePlan.reminder(for: card, allDayTime: "09:00", now: now, calendar: calendar)
        XCTAssertEqual(r?.remindAt, now)
        XCTAssertEqual(r?.dueDate, date(2026, 7, 9))
    }

    func testNonCardHasNoReminder() {
        let income = FinanceSnapshot(kind: .income, title: "工资", dayOfMonth: 10)
        XCTAssertNil(FinancePlan.reminder(for: income, allDayTime: "09:00", now: .now))
    }

    func testMonthsSince() {
        XCTAssertEqual(FinancePlan.monthsSince(date(2026, 3, 1), now: date(2026, 7, 8), calendar: calendar), 4)
        XCTAssertEqual(FinancePlan.monthsSince(date(2026, 8, 1), now: date(2026, 7, 8), calendar: calendar), 0)
    }

    func testBackupRoundTripAndOldPayloadDefaults() throws {
        let entry = FinanceEntry(kind: .creditCard, title: "招行", amount: 50000,
                                 dayOfMonth: 20, statementDay: 3, institution: "招商银行")
        let data = try JSONEncoder().encode(entry.backup)
        let restored = FinanceEntry(kind: .income, title: "")
        try JSONDecoder().decode(BackupFinanceEntry.self, from: data).apply(to: restored)
        XCTAssertEqual(restored.kind, .creditCard)
        XCTAssertEqual(restored.statementDay, 3)
        XCTAssertEqual(restored.institution, "招商银行")
        // 只有必需字段的最小记录也能解开。
        let minimal = #"{"uuid":"\#(UUID().uuidString)","kindRaw":"expense"}"#
        let dto = try JSONDecoder().decode(BackupFinanceEntry.self, from: Data(minimal.utf8))
        XCTAssertEqual(dto.cadenceRaw, "monthly")
        XCTAssertTrue(dto.remindEnabled)
    }

    func testAssetCategoryOrdering() {
        XCTAssertEqual(AssetCategory.orderedGroups(["其他", "车辆", "收藏品", "房产", "车辆"]),
                       ["房产", "车辆", "收藏品", "其他"])
        XCTAssertEqual(AssetCategory.category(of: ["资产", "房产"], reserved: ["资产"]), "房产")
        XCTAssertEqual(AssetCategory.category(of: ["资产"], reserved: ["资产"]), "其他")
    }

    func testNetWorth() {
        let result = FinancePlan.netWorth([
            (value: 3_000_000, liability: 1_200_000, currency: "CNY"),
            (value: 150_000, liability: nil, currency: "CNY"),
            (value: 1000, liability: nil, currency: "USD"),
            (value: nil, liability: nil, currency: "CNY"),
        ], in: "CNY") { amount, from, _ in from == "USD" ? amount * 7 : nil }
        XCTAssertEqual(result.assets, 3_157_000, accuracy: 0.01)
        XCTAssertEqual(result.liabilities, 1_200_000, accuracy: 0.01)
        XCTAssertEqual(result.net, 1_957_000, accuracy: 0.01)
        XCTAssertEqual(result.unvaluedCount, 1)
        XCTAssertEqual(result.missingCurrencies, [])
    }
}
