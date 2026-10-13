import XCTest
@testable import LodoCore

/// 体检报告纯逻辑 + `parseCheckupPayload` 单测(不碰 SwiftData、不发请求)。
final class CheckupPlanTests: XCTestCase {

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
        flag: CheckupFlag? = nil, category: String = "", conclusion: String = "",
        advice: String = "", report: UUID, date: String, index: Int = 0,
        kind: CheckupEntryKind = .item
    ) -> CheckupEntryValue {
        CheckupEntryValue(reportID: report, kind: kind, category: category, name: name,
                          value: value, unit: unit, referenceRange: reference, flag: flag,
                          conclusion: conclusion, advice: advice, date: day(date), sortIndex: index)
    }

    // MARK: - 数值

    func testNumericValue() {
        XCTAssertEqual(CheckupPlan.numericValue("5.6"), 5.6)
        XCTAssertEqual(CheckupPlan.numericValue("<0.5"), 0.5)
        XCTAssertEqual(CheckupPlan.numericValue("≥ 10"), 10)
        XCTAssertEqual(CheckupPlan.numericValue("1,234"), 1234)
        XCTAssertEqual(CheckupPlan.numericValue("5.6↑"), 5.6)
        XCTAssertEqual(CheckupPlan.numericValue("-1.2"), -1.2)
        XCTAssertNil(CheckupPlan.numericValue("阴性"))
        // 尿常规的 "1+"、镜检的 "2-5" 不是一个数,画线是错的。
        XCTAssertNil(CheckupPlan.numericValue("1+"))
        XCTAssertNil(CheckupPlan.numericValue("2-5"))
        XCTAssertNil(CheckupPlan.numericValue(""))
    }

    func testReferenceBounds() {
        XCTAssertEqual(CheckupPlan.referenceBounds("3.9-6.1").low, 3.9)
        XCTAssertEqual(CheckupPlan.referenceBounds("3.9-6.1").high, 6.1)
        XCTAssertEqual(CheckupPlan.referenceBounds("3.9~6.1").high, 6.1)
        XCTAssertEqual(CheckupPlan.referenceBounds("3.9–6.1").low, 3.9)
        XCTAssertNil(CheckupPlan.referenceBounds("<5.2").low)
        XCTAssertEqual(CheckupPlan.referenceBounds("<5.2").high, 5.2)
        XCTAssertEqual(CheckupPlan.referenceBounds(">1.04").low, 1.04)
        XCTAssertNil(CheckupPlan.referenceBounds("阴性").low)
        XCTAssertNil(CheckupPlan.referenceBounds("阴性").high)
    }

    /// 报告没标高低时按参考范围推;标了以标的为准。
    func testEffectiveFlag() {
        XCTAssertEqual(make("血糖", "6.5", reference: "3.9-6.1", report: report1, date: "2026-01-01")
            .effectiveFlag, .high)
        XCTAssertEqual(make("血糖", "5.0", reference: "3.9-6.1", report: report1, date: "2026-01-01")
            .effectiveFlag, .normal)
        XCTAssertEqual(make("血糖", "5.0", reference: "3.9-6.1", flag: .high,
                             report: report1, date: "2026-01-01").effectiveFlag, .high)
        XCTAssertNil(make("血糖", "5.0", report: report1, date: "2026-01-01").effectiveFlag)
        XCTAssertNil(make("乙肝表面抗原", "阴性", reference: "阴性", report: report1, date: "2026-01-01")
            .effectiveFlag)
    }

    // MARK: - 时间轴

    /// 全半角括号、空格写法不同的同一项归到一起,按日期从早到晚。
    func testMetricsMergeSameIndicatorAcrossReports() {
        let entries = [
            make("总胆固醇（TC）", "5.8", reference: "<5.2", category: "血脂",
                  report: report2, date: "2026-05-01", index: 0),
            make("总胆固醇(TC)", "5.1", reference: "<5.2", category: "血脂",
                  report: report1, date: "2025-05-01", index: 0),
            make("腹部B超", category: "影像", conclusion: "脂肪肝(轻度)",
                  report: report2, date: "2026-05-01", index: 1),
            make("", advice: "低脂饮食", report: report2, date: "2026-05-01", kind: .advice),
        ]
        let metrics = CheckupPlan.metrics(from: entries)
        XCTAssertEqual(metrics.count, 2)
        let cholesterol = metrics[0]
        XCTAssertEqual(cholesterol.records.map(\.value), ["5.1", "5.8"])
        XCTAssertEqual(cholesterol.name, "总胆固醇（TC）")
        XCTAssertTrue(cholesterol.isNumeric)
        XCTAssertEqual(cholesterol.points.map(\.value), [5.1, 5.8])
        XCTAssertEqual(cholesterol.referenceBounds.high, 5.2)
        XCTAssertFalse(metrics[1].isNumeric)
    }

    func testGroupedKeepsReportOrderAndSkipsAdvice() {
        let entries = [
            make("白细胞", "6", category: "血常规", report: report1, date: "2026-01-01", index: 0),
            make("ALT", "30", category: "肝功能", report: report1, date: "2026-01-01", index: 1),
            make("红细胞", "4.5", category: "血常规", report: report1, date: "2026-01-01", index: 2),
            make("", advice: "多运动", report: report1, date: "2026-01-01", index: 3, kind: .advice),
        ]
        let groups = CheckupPlan.grouped(entries)
        XCTAssertEqual(groups.map(\.category), ["血常规", "肝功能"])
        XCTAssertEqual(groups[0].entries.map(\.name), ["白细胞", "红细胞"])
    }

    func testKnownNamesPreferLatestAndDedupe() {
        let entries = [
            make("血糖", report: report1, date: "2025-01-01"),
            make("空腹血糖", report: report2, date: "2026-01-01"),
            make("血 糖", report: report2, date: "2026-01-01", index: 1),
        ]
        XCTAssertEqual(CheckupPlan.knownNames(entries), ["空腹血糖", "血 糖"])
    }

    // MARK: - 文本

    func testPromptSummaryHasAbnormalAdviceAndChanges() throws {
        let reports = [
            CheckupReportValue(id: report1, title: "2025 体检", date: day("2025-05-01")),
            CheckupReportValue(id: report2, title: "2026 体检", date: day("2026-05-01")),
        ]
        let entries = [
            make("总胆固醇", "5.1", unit: "mmol/L", reference: "<5.2", report: report1, date: "2025-05-01"),
            make("总胆固醇", "5.8", unit: "mmol/L", reference: "<5.2",
                  advice: "建议低脂饮食", report: report2, date: "2026-05-01"),
            make("白细胞", "6.0", reference: "4-10", report: report2, date: "2026-05-01", index: 1),
            make("", advice: "一年后复查", report: report2, date: "2026-05-01", kind: .advice),
        ]
        let summary = try XCTUnwrap(CheckupPlan.promptSummary(reports: reports, entries: entries))
        XCTAssertTrue(summary.contains("2026-05-01"))
        XCTAssertTrue(summary.contains("总胆固醇 5.8 mmol/L"))
        XCTAssertTrue(summary.contains("建议低脂饮食"))
        XCTAssertFalse(summary.contains("白细胞 6.0"))
        XCTAssertTrue(summary.contains("一年后复查"))
        XCTAssertTrue(summary.contains("2025-05-01 5.1 → 2026-05-01 5.8"))
        XCTAssertNil(CheckupPlan.promptSummary(reports: [], entries: entries))
    }

    func testShareTextListsReportsNewestFirst() {
        let reports = [
            CheckupReportValue(id: report1, title: "2025 体检", date: day("2025-05-01")),
            CheckupReportValue(id: report2, title: "2026 体检", date: day("2026-05-01"), institution: "某体检中心"),
        ]
        let entries = [
            make("血压", "120/80", category: "内科", report: report2, date: "2026-05-01"),
            make("血压", "118/78", category: "内科", report: report1, date: "2025-05-01"),
        ]
        let text = CheckupPlan.shareText(profileName: "妈妈", reports: reports, entries: entries)
        let newer = text.range(of: "2026 体检")!.lowerBound
        let older = text.range(of: "2025 体检")!.lowerBound
        XCTAssertLessThan(newer, older)
        XCTAssertTrue(text.contains("体检机构:某体检中心"))
        XCTAssertTrue(text.contains("【内科】"))
    }

    // MARK: - parseCheckupPayload

    func testParseCheckupPayload() throws {
        let payload: [String: Any] = [
            "title": "2026 年度健康体检",
            "date": "2026-05-01",
            "institution": "某体检中心",
            "summary_advice": "建议低脂饮食,一年后复查血脂。",
            "items": [
                ["category": "血脂", "name": "总胆固醇(TC)", "value": 5.8, "unit": "mmol/L",
                 "reference": "<5.2", "flag": "HIGH", "advice": "偏高,建议低脂饮食"],
                ["category": "影像", "name": "腹部B超", "conclusion": "轻度脂肪肝", "flag": "abnormal"],
                ["category": "血常规", "value": "6"],
                ["name": "身高", "value": 170, "flag": "未知"],
            ],
        ]
        let report = try DeepSeekClient.parseCheckupPayload(payload)
        XCTAssertEqual(report.title, "2026 年度健康体检")
        XCTAssertEqual(report.date, day("2026-05-01"))
        XCTAssertEqual(report.institution, "某体检中心")
        XCTAssertEqual(report.summaryAdvice, "建议低脂饮食,一年后复查血脂。")
        // 缺名字的那项跳过。
        XCTAssertEqual(report.items.map(\.name), ["总胆固醇(TC)", "腹部B超", "身高"])
        XCTAssertEqual(report.items[0].value, "5.8")
        XCTAssertEqual(report.items[0].flag, .high)
        XCTAssertEqual(report.items[0].advice, "偏高,建议低脂饮食")
        XCTAssertEqual(report.items[1].conclusion, "轻度脂肪肝")
        XCTAssertEqual(report.items[2].value, "170")
        XCTAssertNil(report.items[2].flag)
    }

    func testParseCheckupPayloadRequiresItems() {
        XCTAssertThrowsError(try DeepSeekClient.parseCheckupPayload(["title": "x"]))
        XCTAssertEqual(try DeepSeekClient.parseCheckupPayload(["items": []]).items, [])
    }
}
