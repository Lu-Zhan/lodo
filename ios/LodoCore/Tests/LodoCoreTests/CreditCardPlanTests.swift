import XCTest
@testable import LodoCore

final class CreditCardPlanTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func card(due: Int? = 13, statement: Int? = 25,
                      _ settings: CreditCardSettings = CreditCardSettings()) -> FinanceSnapshot {
        FinanceSnapshot(kind: .creditCard, title: "招行", dayOfMonth: due, statementDay: statement,
                        card: settings)
    }

    func testDefaultsKeepOldRepaymentBehaviour() {
        let c = card()
        XCTAssertTrue(CreditCardPlan.isActive(c, kind: .repayment))
        XCTAssertFalse(CreditCardPlan.isActive(c, kind: .statement))
        XCTAssertFalse(CreditCardPlan.isActive(c, kind: .annualFee))
        let r = CreditCardPlan.reminder(for: c, kind: .repayment, allDayTime: "09:00",
                                        now: date(2026, 7, 8, 9), calendar: calendar)
        XCTAssertEqual(r?.dueDate, date(2026, 7, 13))
        XCTAssertEqual(r?.remindAt, date(2026, 7, 12, 9))
        XCTAssertEqual(r?.kind, .repayment)
    }

    /// 账单 25 号、还款次月 13 号:两种日子各自算,不从账单日去推还款日。
    func testStatementAndRepaymentAcrossMonths() {
        let c = card(CreditCardSettings(statementRemind: true))
        let now = date(2026, 7, 20, 10)
        let due = CreditCardPlan.reminder(for: c, kind: .repayment, allDayTime: "09:00", now: now,
                                          calendar: calendar)
        let stmt = CreditCardPlan.reminder(for: c, kind: .statement, allDayTime: "09:00", now: now,
                                           calendar: calendar)
        XCTAssertEqual(due?.dueDate, date(2026, 8, 13))
        XCTAssertEqual(stmt?.dueDate, date(2026, 7, 25))
        XCTAssertEqual(stmt?.remindAt, date(2026, 7, 25, 9), "默认账单日当天提醒")
        XCTAssertEqual(stmt?.cycle, "2026-07-25")
    }

    func testLeadDaysAndPastTimeFiresNow() {
        let c = card(CreditCardSettings(repaymentLeadDays: 3))
        let r = CreditCardPlan.reminder(for: c, kind: .repayment, allDayTime: "20:30",
                                        now: date(2026, 7, 1), calendar: calendar)
        XCTAssertEqual(r?.remindAt, date(2026, 7, 10, 20, 30))
        let late = date(2026, 7, 11, 8)
        let r2 = CreditCardPlan.reminder(for: c, kind: .repayment, allDayTime: "20:30", now: late,
                                         calendar: calendar)
        XCTAssertEqual(r2?.remindAt, late)
        XCTAssertEqual(r2?.scheduledAt, date(2026, 7, 10, 20, 30))
        XCTAssertEqual(r2?.dueDate, date(2026, 7, 13))
    }

    func testLeadDaysAreClamped() {
        let c = card(CreditCardSettings(repaymentLeadDays: 40))
        let r = CreditCardPlan.reminder(for: c, kind: .repayment, allDayTime: "09:00",
                                        now: date(2026, 7, 1), calendar: calendar)
        XCTAssertEqual(r?.scheduledAt, date(2026, 6, 28, 9), "月度提醒最多提前 15 天")
    }

    func testInvalidAllDayTimeFallsBackToNine() {
        let r = CreditCardPlan.reminder(for: card(), kind: .repayment, allDayTime: "25:99",
                                        now: date(2026, 7, 1), calendar: calendar)
        XCTAssertEqual(r?.scheduledAt, date(2026, 7, 12, 9))
    }

    func testAnnualFeeFixedDateAndLeap() {
        var s = CreditCardSettings(annualFeeAmount: 480, annualFeeBasis: .fixedDate,
                                   annualFeeMonth: 2, annualFeeDay: 29, annualFeeRemind: true)
        XCTAssertEqual(CreditCardPlan.nextAnnualFeeDate(s, onOrAfter: date(2026, 7, 8), calendar: calendar),
                       date(2027, 2, 28), "平年落 2/28")
        XCTAssertEqual(CreditCardPlan.nextAnnualFeeDate(s, onOrAfter: date(2027, 3, 1), calendar: calendar),
                       date(2028, 2, 29))
        s.annualFeeMonth = 11
        s.annualFeeDay = 1
        let c = card(s)
        XCTAssertTrue(CreditCardPlan.isActive(c, kind: .annualFee))
        let r = CreditCardPlan.reminder(for: c, kind: .annualFee, allDayTime: "09:00",
                                        now: date(2026, 7, 8), calendar: calendar)
        XCTAssertEqual(r?.dueDate, date(2026, 11, 1))
        XCTAssertEqual(r?.scheduledAt, date(2026, 10, 2, 9), "默认提前 30 天")
        XCTAssertEqual(r?.createAfter, date(2026, 8, 3, 9), "提醒前 60 天内才建任务")
    }

    func testAnnualFeeOpeningMonthUsesFirstDay() {
        let s = CreditCardSettings(annualFeeAmount: 300, annualFeeBasis: .openingMonth, annualFeeMonth: 3)
        XCTAssertEqual(CreditCardPlan.nextAnnualFeeDate(s, onOrAfter: date(2026, 7, 8), calendar: calendar),
                       date(2027, 3, 1))
        XCTAssertEqual(CreditCardPlan.nextAnnualFeeDate(s, onOrAfter: date(2027, 3, 1, 12), calendar: calendar),
                       date(2027, 3, 1), "当天也算")
    }

    func testAnnualFeeNotActiveWhenFreeOrUnknown() {
        let free = CreditCardSettings(annualFeeAmount: 0, annualFeeBasis: .fixedDate,
                                      annualFeeMonth: 5, annualFeeDay: 1, annualFeeRemind: true)
        XCTAssertFalse(CreditCardPlan.isActive(card(free), kind: .annualFee))
        let unknown = CreditCardSettings(annualFeeAmount: 480, annualFeeBasis: .unknown,
                                         annualFeeMonth: 5, annualFeeRemind: true)
        XCTAssertFalse(CreditCardPlan.isActive(card(unknown), kind: .annualFee))
        let noDay = CreditCardSettings(annualFeeAmount: 480, annualFeeBasis: .fixedDate,
                                       annualFeeMonth: 5, annualFeeRemind: true)
        XCTAssertFalse(CreditCardPlan.isActive(card(noDay), kind: .annualFee))
        // 金额没填但日子填了:照样可以提醒(先记日子,金额以后补)。
        let noAmount = CreditCardSettings(annualFeeBasis: .openingMonth, annualFeeMonth: 5,
                                          annualFeeRemind: true)
        XCTAssertTrue(CreditCardPlan.isActive(card(noAmount), kind: .annualFee))
    }

    func testStatementInactiveWithoutDay() {
        let c = card(statement: nil, CreditCardSettings(statementRemind: true))
        XCTAssertFalse(CreditCardPlan.isActive(c, kind: .statement))
        XCTAssertNil(CreditCardPlan.reminder(for: c, kind: .statement, allDayTime: "09:00",
                                             now: date(2026, 7, 8), calendar: calendar))
    }

    func testSettingsDecodeMissingKeysAsDefaults() throws {
        let s = try JSONDecoder().decode(CreditCardSettings.self, from: Data(#"{"annualFeeAmount": 480}"#.utf8))
        XCTAssertEqual(s.annualFeeAmount, 480)
        XCTAssertTrue(s.repaymentRemind)
        XCTAssertEqual(s.repaymentLeadDays, 1)
        XCTAssertEqual(s.annualFeeLeadDays, 30)
        XCTAssertEqual(s.annualFeeBasis, .unknown)
        let odd = try JSONDecoder().decode(CreditCardSettings.self, from: Data(#"{"annualFeeBasis": "future"}"#.utf8))
        XCTAssertEqual(odd.annualFeeBasis, .unknown)
    }

    func testEntryCardSettingsRoundTripAndBackup() throws {
        let entry = FinanceEntry(kind: .creditCard, title: "招行", dayOfMonth: 13, statementDay: 25)
        XCTAssertEqual(entry.cardSettings, CreditCardSettings(), "老数据就是默认值")
        let s = CreditCardSettings(repaymentRemind: false, repaymentLeadDays: 3, statementRemind: true,
                                   statementLeadDays: 1, annualFeeAmount: 480, annualFeeBasis: .fixedDate,
                                   annualFeeMonth: 11, annualFeeDay: 1, annualFeeWaiver: "刷满 6 次",
                                   annualFeeRemind: true, annualFeeLeadDays: 15)
        entry.cardSettings = s
        XCTAssertEqual(entry.cardSettings, s)
        XCTAssertFalse(entry.remindEnabled)
        let data = try JSONEncoder().encode(entry.backup)
        let restored = FinanceEntry(kind: .income, title: "")
        try JSONDecoder().decode(BackupFinanceEntry.self, from: data).apply(to: restored)
        XCTAssertEqual(restored.cardSettings, s)
        // 老备份没有这些字段:按默认值。
        let old = #"{"uuid":"\#(UUID().uuidString)","kindRaw":"creditCard","remindEnabled":true}"#
        let fromOld = FinanceEntry(kind: .income, title: "")
        try JSONDecoder().decode(BackupFinanceEntry.self, from: Data(old.utf8)).apply(to: fromOld)
        XCTAssertEqual(fromOld.cardSettings, CreditCardSettings())
    }

    func testUnknownBasisRawIsPreserved() {
        let entry = FinanceEntry(kind: .creditCard, title: "招行")
        entry.annualFeeBasisRaw = "anniversary"
        var s = entry.cardSettings
        s.annualFeeWaiver = "x"
        entry.cardSettings = s
        XCTAssertEqual(entry.annualFeeBasisRaw, "anniversary")
    }

    func testReminderMarksPerKind() {
        let entry = FinanceEntry(kind: .creditCard, title: "招行")
        let id = UUID()
        entry.setReminderMark(.annualFee, cycle: "2026-11-01", task: id)
        XCTAssertEqual(entry.reminderMark(.annualFee).task, id)
        XCTAssertEqual(entry.annualFeeReminderCycle, "2026-11-01")
        XCTAssertNil(entry.reminderMark(.repayment).task)
        XCTAssertEqual(entry.reminderMark(.statement).cycle, "")
    }

    func testSharedMappingKeepsCardSettingsWhenOldClientDropsThem() {
        let entry = FinanceEntry(kind: .creditCard, title: "招行", dayOfMonth: 13)
        var s = CreditCardSettings(); s.annualFeeAmount = 480; s.statementRemind = true
        entry.cardSettings = s
        let snap = SharedAssetMapping.snapshot(of: entry)
        XCTAssertNotNil(snap.fields["cardSettings"])
        XCTAssertEqual(SharedAssetMapping.snapshot(of: entry), snap, "同样的设置编出同一个串")

        let other = FinanceEntry(kind: .income, title: "")
        SharedAssetMapping.apply(snap.fields, to: other)
        XCTAssertEqual(other.cardSettings, s)

        // 老客户端推上来的记录没有 cardSettings:不清空本地已有的年费资料。
        var oldFields = snap.fields
        oldFields["cardSettings"] = nil
        oldFields["remindEnabled"] = .bool(false)
        SharedAssetMapping.apply(oldFields, to: other)
        XCTAssertEqual(other.annualFeeAmount, 480)
        XCTAssertFalse(other.remindEnabled)
    }
}
