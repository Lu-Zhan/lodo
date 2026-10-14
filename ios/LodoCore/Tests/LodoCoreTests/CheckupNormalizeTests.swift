import XCTest
@testable import LodoCore

/// 「重新匹配检查项」的纯逻辑:清单、解析 AI 分组、本地缩写规则、改名与去重。
final class CheckupNormalizeTests: XCTestCase {

    private let report1 = UUID()
    private let report2 = UUID()

    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    private func make(
        _ name: String, _ value: String = "", unit: String = "", reference: String = "",
        flag: CheckupFlag? = nil, advice: String = "", report: UUID, date: String, index: Int = 0
    ) -> CheckupEntryValue {
        CheckupEntryValue(reportID: report, category: "肝功能", name: name, value: value, unit: unit,
                          referenceRange: reference, flag: flag, advice: advice,
                          date: day(date), sortIndex: index)
    }

    func testCatalogDedupesByKeyNewestFirst() {
        let entries = [
            make("谷丙转氨酶(ALT)", "38", unit: "U/L", report: report1, date: "2025-05-12"),
            make("ALT", "56", unit: "U/L", report: report2, date: "2026-05-08"),
            make("谷丙转氨酶（ALT）", "40", report: report2, date: "2026-05-08", index: 1),
        ]
        let catalog = CheckupNormalizer.catalog(entries)
        XCTAssertEqual(catalog.map(\.name), ["ALT", "谷丙转氨酶（ALT）"])
        XCTAssertEqual(catalog[1].count, 2)
        XCTAssertEqual(CheckupNormalizer.promptLines(catalog).components(separatedBy: "\n").first,
                       "1|ALT|肝功能|U/L|56 U/L")
    }

    func testParseGroupsValidatesIDs() {
        let catalog = ["ALT", "谷丙转氨酶", "AST", "谷草转氨酶", "血压"].map {
            CheckupNormalizer.NameInfo(name: $0, category: "", unit: "", sample: "", count: 1)
        }
        let payload: [String: Any] = ["groups": [
            ["name": "谷丙转氨酶(ALT)", "ids": [1, 2]],
            ["name": "", "ids": [3, "4", 9]],
            ["name": "重复", "ids": [2, 5]],   // 2 已经用过,只剩一个 → 丢掉
            ["name": "单个", "ids": [5]],
        ]]
        let groups = CheckupNormalizer.parseGroups(payload, catalog: catalog)
        XCTAssertEqual(groups.map(\.canonical), ["谷丙转氨酶(ALT)", "AST"])
        XCTAssertEqual(groups[1].variants, ["AST", "谷草转氨酶"])
        XCTAssertEqual(CheckupNormalizer.parseGroups([:], catalog: catalog), [])
    }

    func testLocalGroupsByAbbreviation() {
        let catalog = [
            CheckupNormalizer.NameInfo(name: "ALT", category: "", unit: "", sample: "", count: 3),
            CheckupNormalizer.NameInfo(name: "谷丙转氨酶(ALT)", category: "", unit: "", sample: "", count: 1),
            CheckupNormalizer.NameInfo(name: "血压", category: "", unit: "", sample: "", count: 2),
            CheckupNormalizer.NameInfo(name: "总胆固醇(TC)", category: "", unit: "", sample: "", count: 1),
        ]
        let groups = CheckupNormalizer.localGroups(catalog)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].canonical, "谷丙转氨酶(ALT)")   // 带中文的优先
        XCTAssertNil(CheckupNormalizer.abbreviation(of: "血压"))
        XCTAssertEqual(CheckupNormalizer.abbreviation(of: "低密度脂蛋白（LDL-C）"), "ldl-c")
    }

    func testMergeUnionsOverlappingGroupsAIFirst() {
        let ai = [CheckupNameGroup(canonical: "谷丙转氨酶(ALT)", variants: ["Alanine aminotransferase", "谷丙转氨酶"])]
        let local = [CheckupNameGroup(canonical: "ALT", variants: ["ALT", "谷丙转氨酶"])]
        let merged = CheckupNormalizer.merge(ai, local)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].canonical, "谷丙转氨酶(ALT)")
        XCTAssertEqual(Set(merged[0].variants), ["Alanine aminotransferase", "谷丙转氨酶", "ALT"])
    }

    func testPlanRenamesAcrossReports() {
        let old = make("ALT", "38", unit: "U/L", report: report1, date: "2025-05-12")
        let new = make("谷丙转氨酶(ALT)", "56", unit: "U/L", report: report2, date: "2026-05-08")
        let group = CheckupNameGroup(canonical: "谷丙转氨酶(ALT)", variants: ["ALT", "谷丙转氨酶(ALT)"])
        let plan = CheckupNormalizer.plan([old, new], groups: [group])
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.updates[old.id]?.name, "谷丙转氨酶(ALT)")
        XCTAssertTrue(plan.removals.isEmpty)
        XCTAssertEqual(plan.groups.first?.variants, ["ALT"])
        XCTAssertEqual(plan.groups.first?.recordCount, 2)
        XCTAssertEqual(CheckupPlan.metrics(from: [plan.updates[old.id]!, new]).count, 1)
    }

    func testPlanDedupesSameReportAndFillsFields() {
        let rich = make("谷丙转氨酶(ALT)", "56", unit: "U/L", reference: "9-50", report: report1, date: "2026-05-08", index: 3)
        let dup = make("ALT", "56", flag: .high, advice: "复查", report: report1, date: "2026-05-08", index: 7)
        let group = CheckupNameGroup(canonical: "谷丙转氨酶(ALT)", variants: ["ALT", "谷丙转氨酶(ALT)"])
        let plan = CheckupNormalizer.plan([rich, dup], groups: [group])
        XCTAssertEqual(plan.removals.map(\.id), [dup.id])
        let kept = plan.updates[rich.id]
        XCTAssertEqual(kept?.flag, .high)
        XCTAssertEqual(kept?.advice, "复查")
        XCTAssertEqual(kept?.referenceRange, "9-50")
    }

    func testPlanKeepsConflictingResults() {
        // 同一份报告里同名但结果不同(左右眼/两次测量):都留着。
        let a = make("视力", "1.0", report: report1, date: "2026-05-08", index: 0)
        let b = make("视力", "0.8", report: report1, date: "2026-05-08", index: 1)
        let plan = CheckupNormalizer.plan([a, b], groups: [])
        XCTAssertTrue(plan.isEmpty)
    }

    func testPlanRemovesExactDuplicatesWithoutGroups() {
        let a = make("空腹血糖", "5.60", unit: "mmol/L", report: report1, date: "2026-05-08", index: 0)
        let b = make("空腹血糖", "5.6", report: report1, date: "2026-05-08", index: 1)
        let plan = CheckupNormalizer.plan([a, b], groups: [])
        XCTAssertEqual(plan.removals.map(\.id), [b.id])
    }

    func testMetricsCollapseSameDayRepeats() {
        // 同一份报告导入了两次:时间轴上只算一次。
        let a = make("空腹血糖", "5.6", report: report1, date: "2026-05-08")
        let b = make("空腹血糖", "5.6", report: report2, date: "2026-05-08")
        XCTAssertEqual(CheckupPlan.metrics(from: [a, b]).first?.records.count, 1)
    }
}
