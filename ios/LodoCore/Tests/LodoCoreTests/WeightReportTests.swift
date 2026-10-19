import XCTest
@testable import LodoCore

/// 体重秤报告导入的纯解析(不发请求):单位换算、限幅、日期、去重、备份兼容。
final class WeightReportTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func parse(_ measurements: [[String: Any]], now: Date? = nil) throws -> ParsedWeightReport {
        try WeightReport.parse(["title": "小米体脂秤", "measurements": measurements],
                               now: now ?? at(19, 20), calendar: calendar)
    }

    func testFullMeasurementInKilograms() throws {
        let report = try parse([[
            "time": "2026-10-18 07:32", "weight": 62.4, "body_fat": 21.3, "muscle": 46.2,
            "visceral_fat": 7, "bmr": 1420, "water": 54.8, "bone": 2.6, "mass_unit": "kg",
        ]])
        XCTAssertEqual(report.title, "小米体脂秤")
        XCTAssertEqual(report.droppedValues, 0)
        let m = try XCTUnwrap(report.measurements.first)
        XCTAssertEqual(m.date, at(18, 7, 32))
        XCTAssertFalse(m.dateOnly)
        XCTAssertEqual(m.weightKg, 62.4)
        XCTAssertEqual(m.bodyFatPercent, 21.3)
        XCTAssertEqual(m.muscleMassKg, 46.2)
        XCTAssertEqual(m.visceralFatLevel, 7)
        XCTAssertEqual(m.basalMetabolicKcal, 1420)
        XCTAssertEqual(m.bodyWaterPercent, 54.8)
        XCTAssertEqual(m.boneMassKg, 2.6)
    }

    func testUnitsConvertToKilogramsAndKcal() throws {
        let jin = try parse([["time": "2026-10-18", "weight": 124.8, "muscle": "92.4", "mass_unit": "斤",
                              "bmr": 5941, "bmr_unit": "kJ"]]).measurements[0]
        XCTAssertEqual(jin.weightKg, 62.4)
        XCTAssertEqual(jin.muscleMassKg, 46.2)
        XCTAssertEqual(jin.basalMetabolicKcal, 1420)
        XCTAssertTrue(jin.dateOnly)
        let pounds = try parse([["weight": 137.6, "mass_unit": "lb"]]).measurements[0]
        XCTAssertEqual(pounds.weightKg, 62.4)
        // 体重用斤、肌肉量和骨量用公斤:各按各的单位换算。
        let mixed = try parse([["weight": 124.8, "weight_unit": "斤", "muscle": 46.2, "muscle_unit": "kg",
                                "bone": 2.6, "bone_unit": "kg"]]).measurements[0]
        XCTAssertEqual(mixed.weightKg, 62.4)
        XCTAssertEqual(mixed.muscleMassKg, 46.2)
        XCTAssertEqual(mixed.boneMassKg, 2.6)
    }

    /// 认不出的单位、离谱的数、布尔值、范围串、带单位的串:那一项丢掉,其余照留,并如实计数。
    func testBadValuesAreDroppedNotClamped() throws {
        let report = try parse([
            ["time": "2026-10-18", "weight": 62.4, "body_fat": 95, "water": true, "bone": "2.6kg"],
            ["time": "2026-10-17", "weight": 60, "mass_unit": "stone"],
            ["time": "2026-10-16", "weight": "60-65"],
            ["time": "2026-10-15", "weight": 62, "muscle": 70],
        ])
        XCTAssertEqual(report.measurements.count, 2)               // 10-17、10-16 两条一个数都没剩
        XCTAssertEqual(report.measurements.map(\.weightKg), [62, 62.4])
        XCTAssertNil(report.measurements[1].bodyFatPercent)
        XCTAssertNil(report.measurements[1].bodyWaterPercent)
        XCTAssertNil(report.measurements[0].muscleMassKg)          // 肌肉量比体重还大
        XCTAssertEqual(report.droppedValues, 3)                    // 体脂 95、stone 单位的体重、肌肉量 70
    }

    func testDates() throws {
        // 未来的日期(OCR 认错年份)当作没看到;2 月 30 日这种不存在的日子也不认。
        let report = try parse([
            ["time": "2052-10-18 07:00", "weight": 62],
            ["time": "2026-02-30", "weight": 61],
        ])
        XCTAssertTrue(report.measurements.allSatisfy { $0.date == nil })
        // 明天(哪怕离现在不到一天)也不认;今天只有日期的,存成不晚于现在的时刻。
        let near = try parse([
            ["time": "2026-10-20", "weight": 62],
            ["time": "2026-10-19 21:30", "weight": 62.1],
            ["time": "2026-10-19", "weight": 62.2],
        ], now: at(19, 9))
        XCTAssertEqual(near.measurements.compactMap(\.date), [at(19, 9)])
        XCTAssertTrue(near.measurements.first { $0.date != nil }?.dateOnly ?? false)
        XCTAssertThrowsError(try WeightReport.parse(["items": []], calendar: calendar))
    }

    func testDuplicateOnlyMatchesSameDayAndWeight() {
        let existing = [WeightEntry(date: at(18, 8), weightKg: 62.4, bodyFatPercent: nil),
                        WeightEntry(date: at(17, 8), weightKg: 61.0, bodyFatPercent: nil, fromHealth: true)]
        var m = ParsedWeightMeasurement(date: at(18, 7, 32), weightKg: 62.42)
        XCTAssertTrue(WeightReport.isDuplicate(m, existing: existing, calendar: calendar))
        m.weightKg = 62.6
        XCTAssertFalse(WeightReport.isDuplicate(m, existing: existing, calendar: calendar))
        // 健康 App 的体重不算"记过"(手记/导入会盖住它,本来就该落)。
        let fromHealth = ParsedWeightMeasurement(date: at(17, 9), weightKg: 61.0)
        XCTAssertFalse(WeightReport.isDuplicate(fromHealth, existing: existing, calendar: calendar))
        // 没日期的不判重复(确认页要用户先定日子)。
        XCTAssertFalse(WeightReport.isDuplicate(ParsedWeightMeasurement(weightKg: 62.4), existing: existing,
                                                calendar: calendar))
    }

    /// 老备份里的体重记录没有身体成分那几个 key,照样能解出来。
    func testOldBackupWeightRecordDecodes() throws {
        let json = """
        {"uuid": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "date": 0, "weightKg": 62.4,
         "note": "", "createdAt": 0}
        """
        let record = try JSONDecoder().decode(BackupWeightRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.weightKg, 62.4)
        XCTAssertNil(record.muscleMassKg)
        XCTAssertNil(record.reportUUID)
    }
}
