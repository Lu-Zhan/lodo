import XCTest
@testable import LodoCore

/// 经期预测的离线单测。基准时间沿用 2026-07-08(周三)那一套惯例,换成上海时区的公历。
final class CyclePredictionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func add(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    /// 从 `first` 开始按 `lengths` 依次排出一串经期,每次 `period` 天、都记了结束日。
    private func periods(from first: Date, lengths: [Int], period: Int = 5) -> [CyclePlan.Period] {
        var start = first
        var result: [CyclePlan.Period] = []
        for length in lengths + [0] {
            result.append(CyclePlan.Period(start: start, end: add(period - 1, to: start), source: .manual(UUID())))
            start = add(length, to: start)
        }
        return result
    }

    private func predict(_ periods: [CyclePlan.Period], today: Date) -> CyclePrediction.Result {
        CyclePrediction.predict(periods, today: today, calendar: calendar)
    }

    // MARK: - 门槛

    func testNoRecordsAndSingleRecord() {
        XCTAssertEqual(predict([], today: day(7, 8)).phase, .noRecords)
        // 只记过一次、已经结束:没有个人预测,不默认"28 天后会来"。
        let once = [CyclePlan.Period(start: day(7, 1), end: day(7, 5), source: .manual(UUID()))]
        let result = predict(once, today: day(7, 20))
        XCTAssertEqual(result.phase, .insufficient)
        XCTAssertNil(result.nextStart)
        XCTAssertFalse(result.canRemind)
    }

    func testOneIntervalShowsLastLengthButNoPrediction() {
        let result = predict(periods(from: day(6, 1), lengths: [29]), today: day(7, 10))
        XCTAssertEqual(result.phase, .insufficient)
        XCTAssertEqual(result.lastIntervalLength, 29)
        XCTAssertNil(result.nextStart)
    }

    func testTwoIntervalsPredictWithWideWindowAndLowEvidence() {
        let history = periods(from: day(5, 1), lengths: [28, 30])
        let result = predict(history, today: day(7, 10))
        let last = history.last!.start                  // 5/1 + 58 = 6/28
        XCTAssertEqual(result.lastStart, last)
        XCTAssertEqual(result.validCycles, 2)
        // 加权中位数:近的 30 权重 1、28 权重 0.85,一半的累计落在 30。
        XCTAssertEqual(result.cycleLength, 30)
        XCTAssertEqual(result.nextStart?.center, add(30, to: last))
        // 两个周期:窗口至少 ±7 天。
        XCTAssertEqual(result.nextStart?.lower, add(23, to: last))
        XCTAssertEqual(result.nextStart?.upper, add(37, to: last))
        XCTAssertEqual(result.startEvidence, .low)
        XCTAssertFalse(result.canRemind)
        XCTAssertNil(result.stable)                      // 不到 3 个周期不评规律
    }

    func testRegularHistoryGivesNarrowWindowHighEvidenceAndReminder() {
        let history = periods(from: day(1, 1), lengths: [28, 29, 28, 28, 29, 28])
        let last = history.last!.start
        let result = predict(history, today: add(10, to: last))
        XCTAssertEqual(result.validCycles, 6)
        XCTAssertEqual(result.cycleLength, 28)
        XCTAssertEqual(result.nextStart?.center, add(28, to: last))
        XCTAssertEqual(result.nextStart?.lower, add(26, to: last))   // 5–6 个周期下限 ±2
        XCTAssertEqual(result.startEvidence, .high)
        XCTAssertEqual(result.stable, true)
        XCTAssertTrue(result.canRemind)
        XCTAssertEqual(result.phase, .before)
        XCTAssertEqual(result.daysUntilStart, 18)
        XCTAssertEqual(result.periodLength, 5)
        XCTAssertFalse(result.periodLengthIsDefault)
    }

    // MARK: - 漏记

    func testDoubleLengthIntervalIsMarkedSkippedAndNotUsed() {
        let history = periods(from: day(1, 1), lengths: [28, 29, 28, 56, 28])
        let result = predict(history, today: add(5, to: history.last!.start))
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.intervals.first { $0.length == 56 }?.excluded, .likelySkipped)
        XCTAssertEqual(result.validCycles, 4)
        XCTAssertEqual(result.cycleLength, 28)
    }

    func testWithoutBaselineLongIntervalIsKept() {
        // 只有 28 和 56:基线不够,不断言漏记,两段都留着(依据较少)。
        let history = periods(from: day(3, 1), lengths: [28, 56])
        let result = predict(history, today: add(5, to: history.last!.start))
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.validCycles, 2)
        XCTAssertEqual(result.startEvidence, .low)
    }

    func testOutOfRangeIntervalShownButExcluded() {
        let history = periods(from: day(1, 1), lengths: [28, 10, 29, 28])
        let result = predict(history, today: add(3, to: history.last!.start))
        XCTAssertEqual(result.intervals.first { $0.length == 10 }?.excluded, .outOfRange)
        XCTAssertEqual(result.validCycles, 3)
    }

    // MARK: - 状态

    func testWindowEdgesAndLate() {
        let history = periods(from: day(1, 1), lengths: [28, 29, 28, 28, 29, 28])
        let last = history.last!.start
        let upper = add(30, to: last)
        XCTAssertEqual(predict(history, today: add(26, to: last)).phase, .inWindow)   // 下界当天
        XCTAssertEqual(predict(history, today: upper).phase, .inWindow)               // 上界当天不算推迟
        XCTAssertEqual(predict(history, today: add(1, to: upper)).phase, .late(days: 1))
        XCTAssertEqual(predict(history, today: add(4, to: upper)).phase, .late(days: 4))
    }

    func testInPeriodCountsDownToEnd() {
        var history = periods(from: day(1, 1), lengths: [28, 29, 28, 28, 29])
        let start = add(28, to: history.last!.start)
        history.append(CyclePlan.Period(start: start, end: nil, source: .manual(UUID())))
        let result = predict(history, today: add(2, to: start))
        XCTAssertEqual(result.phase, .inPeriod(day: 3))
        XCTAssertEqual(result.currentEnd?.center, add(4, to: start))   // 典型 5 天,含当天
        XCTAssertEqual(result.daysUntilEnd, 2)
        // 经期中照样给出下一次的预测(锚在这次开始)。
        XCTAssertEqual(result.nextStart?.center, add(28, to: start))
    }

    func testOpenPeriodOverTenDaysNeedsConfirmation() {
        let start = day(7, 1)
        let history = [CyclePlan.Period(start: start, end: nil, source: .manual(UUID()))]
        XCTAssertEqual(predict(history, today: add(12, to: start)).phase, .endUnconfirmed(day: 13))
    }

    func testDefaultPeriodLengthWhenNeverClosed() {
        let start = day(7, 1)
        let history = [CyclePlan.Period(start: start, end: nil, source: .manual(UUID()))]
        let result = predict(history, today: add(1, to: start))
        XCTAssertTrue(result.periodLengthIsDefault)
        XCTAssertEqual(result.currentEnd?.center, add(4, to: start))
        XCTAssertEqual(result.currentEnd?.upper, add(7, to: start))    // 5 + 3 − 1
        XCTAssertEqual(result.endEvidence, .low)
    }

    func testStaleLastStartLowersEvidence() {
        let history = periods(from: day(1, 1), lengths: [28, 29, 28, 28, 29, 28])
        let result = predict(history, today: add(120, to: history.last!.start))
        XCTAssertEqual(result.startEvidence, .low)
        XCTAssertFalse(result.canRemind)
    }

    // MARK: - 小工具与提醒

    func testWeightedMedianAndSpread() {
        XCTAssertEqual(CyclePrediction.weightedMedian([28, 28, 28]), 28)
        XCTAssertEqual(CyclePrediction.weightedMedian([30, 26, 26, 26]), 26)
        // MAD 为 0 时由下限决定。
        XCTAssertEqual(CyclePrediction.spread([28, 28, 28, 28, 28], center: 28, floor: 2), 2)
        // 波动大时不压窄:|Li − 28| 的 P80。
        XCTAssertEqual(CyclePrediction.spread([22, 35, 28, 24, 33], center: 28, floor: 2), 15)
    }

    func testReminderBeforeWindowLowerBound() {
        let history = periods(from: day(1, 1), lengths: [28, 29, 28, 28, 29, 28])
        let last = history.last!.start
        let result = predict(history, today: add(10, to: last))
        let fire = CyclePrediction.reminderDate(result, time: "09:00", now: add(10, to: last), calendar: calendar)
        XCTAssertEqual(fire, calendar.date(bySettingHour: 9, minute: 0, second: 0, of: add(24, to: last)))
        XCTAssertNil(CyclePrediction.reminderDate(result, time: "9am", now: add(10, to: last), calendar: calendar))
        XCTAssertNil(CyclePrediction.reminderDate(result, time: "09:00", now: add(25, to: last), calendar: calendar))
    }
}

extension CyclePredictionTests {
    // MARK: - 验收补的回归

    /// 健康 App 的经期:最后一天有记录是昨天、还在预计结束范围里 → 仍算经期中;前天就不算了。
    func testHealthOngoingUsesLastObservedDay() {
        let start = day(7, 1)
        let health = [CyclePlan.Period(start: start, end: add(2, to: start), source: .health)]
        XCTAssertEqual(predict(health, today: add(3, to: start)).phase, .inPeriod(day: 4))
        XCTAssertNotEqual(predict(health, today: add(4, to: start)).phase, .inPeriod(day: 5))
        // 健康 App 的末日不进经期天数估计、也不在周期图上画成确定的经期长度。
        let history = periods(from: day(1, 1), lengths: [28, 29]).map {
            CyclePlan.Period(start: $0.start, end: $0.end, source: .health)
        }
        let result = predict(history, today: day(4, 1))
        XCTAssertTrue(result.periodLengthIsDefault)
        XCTAssertTrue(result.intervals.allSatisfy { $0.periodLength == nil })
    }

    /// 手记开着、过了预计结束范围上界 → 待确认(按范围判,不是死板的 10 天)。
    func testOpenManualPastEndWindowNeedsConfirmation() {
        var history = periods(from: day(1, 1), lengths: [28, 29, 28], period: 4)
        let start = add(28, to: history.last!.start)
        history.append(CyclePlan.Period(start: start, end: nil, source: .manual(UUID())))
        // 典型 4 天,范围上界 = 第 5 天(4 + 1 − 1 的那天往后一天):第 6 天就待确认了。
        let upper = predict(history, today: start).currentEnd!.upper
        XCTAssertEqual(predict(history, today: upper).phase, .inPeriod(day: 1 + 4))
        XCTAssertEqual(predict(history, today: add(1, to: upper)).phase, .endUnconfirmed(day: 6))
    }

    /// 结束日在今天之后的(手误)不进经期天数估计。
    func testFutureEndIgnoredForLength() {
        let start = day(7, 1)
        let history = [CyclePlan.Period(start: start, end: add(20, to: start), source: .manual(UUID()))]
        XCTAssertTrue(predict(history, today: add(2, to: start)).periodLengthIsDefault)
    }

    /// 同一天开始的两条手记(重复导入 / 两台设备各点一次)只算一次,不出现 0 天的周期。
    func testDuplicateSameDayStartsMerged() {
        var history = periods(from: day(1, 1), lengths: [28, 29, 28])
        history.append(CyclePlan.Period(start: history.last!.start, end: nil, source: .manual(UUID())))
        let merged = CyclePlan.merge(manual: history, health: [], today: day(5, 1), calendar: calendar)
        XCTAssertEqual(merged.count, 4)
        XCTAssertNotNil(merged.last?.end)                       // 留下有结束日的那条
        let result = predict(merged, today: day(5, 1))
        XCTAssertFalse(result.intervals.contains { $0.length == 0 })
    }

    /// 同一天两条同样完整的手记:不管输入顺序,挑出来的都是同一条。
    func testDuplicateSameDayPickIsOrderIndependent() {
        let start = day(7, 1)
        let a = CyclePlan.Period(start: start, end: add(4, to: start), source: .manual(UUID()))
        let b = CyclePlan.Period(start: start, end: add(6, to: start), source: .manual(UUID()))
        let one = CyclePlan.merge(manual: [a, b], health: [], today: day(7, 20), calendar: calendar)
        let two = CyclePlan.merge(manual: [b, a], health: [], today: day(7, 20), calendar: calendar)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one, two)
    }

    /// 进了「结束待确认」,预计结束范围照样给出来(补记判断要用),但不再倒计时。
    func testEndUnconfirmedKeepsEndWindow() {
        let start = day(7, 1)
        let history = [CyclePlan.Period(start: start, end: nil, source: .manual(UUID()))]
        let result = predict(history, today: add(9, to: start))
        XCTAssertEqual(result.phase, .endUnconfirmed(day: 10))
        XCTAssertEqual(result.currentEnd?.upper, add(7, to: start))
        XCTAssertNil(result.daysUntilEnd)
    }
}

