import XCTest
@testable import LodoCore

/// HealthReport 的纯逻辑单测(不碰 HealthKit,不需要模拟器)。
/// 基准时间沿用 SchedulerTests 的 2026-07-08 09:00。
final class HealthReportTests: XCTestCase {
    let calendar = Calendar.current
    var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 0))!
    }

    /// values[0] 是最早的一天,依次每天 +1 天。
    private func series(_ kind: HealthMetricKind, _ values: [Double]) -> HealthSeries {
        let points = values.enumerated().map { index, value in
            HealthDailyPoint(date: t0.addingTimeInterval(TimeInterval(index * 86400)), value: value)
        }
        return HealthSeries(kind: kind, points: points)
    }

    func testAverageAndLatest() {
        let report = HealthReport(series: [series(.steps, [1000, 2000, 3000])], rangeDays: 3)
        XCTAssertEqual(report.average(.steps)!, 2000, accuracy: 0.001)
        XCTAssertEqual(report.latest(.steps)!, 3000, accuracy: 0.001)
    }

    /// 没有这个指标的数据时返回 nil,而不是 0——"没测"和"是 0"是两回事。
    func testMissingMetricIsNilNotZero() {
        let report = HealthReport(series: [series(.steps, [1000])], rangeDays: 1)
        XCTAssertNil(report.average(.sleepHours))
        XCTAssertNil(report.latest(.sleepHours))
        XCTAssertNil(report.trend(.sleepHours))
    }

    /// 构造时按日期升序排好,乱序传入也不影响 latest。
    func testPointsAreSortedByDate() {
        let unsorted = [
            HealthDailyPoint(date: t0.addingTimeInterval(86400), value: 20),
            HealthDailyPoint(date: t0, value: 10),
        ]
        let report = HealthReport(series: [HealthSeries(kind: .steps, points: unsorted)], rangeDays: 2)
        XCTAssertEqual(report.latest(.steps)!, 20, accuracy: 0.001)
    }

    /// 最近 7 天日均 200,之前 7 天日均 100 → +100%。
    func testTrendComparesTwoWindows() {
        let values = Array(repeating: 100.0, count: 7) + Array(repeating: 200.0, count: 7)
        let report = HealthReport(series: [series(.steps, values)], rangeDays: 14)
        XCTAssertEqual(report.trend(.steps)!, 1.0, accuracy: 0.001)
    }

    func testTrendIsNegativeWhenDeclining() {
        let values = Array(repeating: 200.0, count: 7) + Array(repeating: 150.0, count: 7)
        let report = HealthReport(series: [series(.steps, values)], rangeDays: 14)
        XCTAssertEqual(report.trend(.steps)!, -0.25, accuracy: 0.001)
    }

    /// 数据不足一个完整对比窗口时算不出趋势。
    func testTrendNeedsMoreThanOneWindow() {
        let report = HealthReport(series: [series(.steps, Array(repeating: 100.0, count: 7))], rangeDays: 7)
        XCTAssertNil(report.trend(.steps))
    }

    /// 基准段均值为 0 时除不出百分比,老实返回 nil 而不是 ∞。
    func testTrendNilWhenBaselineIsZero() {
        let values = Array(repeating: 0.0, count: 7) + Array(repeating: 100.0, count: 7)
        let report = HealthReport(series: [series(.steps, values)], rangeDays: 14)
        XCTAssertNil(report.trend(.steps))
    }

    /// 空序列被构造函数直接滤掉,报告仍然可用。
    func testEmptySeriesAreDropped() {
        let report = HealthReport(
            series: [HealthSeries(kind: .steps, points: []), series(.sleepHours, [7])],
            rangeDays: 1)
        XCTAssertEqual(report.series.count, 1)
        XCTAssertNil(report.series(.steps))
        XCTAssertFalse(report.isEmpty)
    }

    func testEmptyReportPromptSummaryIsEmpty() {
        XCTAssertTrue(HealthReport.empty.isEmpty)
        XCTAssertEqual(HealthReport.empty.promptSummary(), "")
    }

    /// 摘要用固定中文(prompt 不跟应用内语言走),带日均、最近一天和趋势。
    func testPromptSummaryFormat() {
        let values = Array(repeating: 100.0, count: 7) + Array(repeating: 200.0, count: 7)
        let report = HealthReport(series: [series(.steps, values)], rangeDays: 14)
        let text = report.promptSummary()
        XCTAssertTrue(text.hasPrefix("最近 14 天的健康数据:"))
        XCTAssertTrue(text.contains("步数:日均 150 步"))
        XCTAssertTrue(text.contains("最近一天 200 步"))
        XCTAssertTrue(text.contains("较上一周期上升 100%"))
    }

    /// 睡眠/体重留一位小数,其余整数。
    func testFractionDigits() {
        XCTAssertEqual(HealthMetricKind.sleepHours.format(7.26), "7.3")
        XCTAssertEqual(HealthMetricKind.bodyMass.format(62.44), "62.4")
        XCTAssertEqual(HealthMetricKind.steps.format(8123.6), "8124")
    }

    /// 门控入口现在返回全集;iOS 27 新增指标时只改这一处的期望。
    func testAvailableKindsCoversAllCases() {
        XCTAssertEqual(HealthMetricKind.availableKinds().count, HealthMetricKind.allCases.count)
    }
}
