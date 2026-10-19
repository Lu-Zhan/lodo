import Foundation

/// 经期预测(单测 `CyclePredictionTests`,不 import HealthKit/SwiftUI)。
///
/// 只有周期历史、没有体温/排卵试纸时,文献里复杂模型相对"近几个周期取中心值"提升有限,
/// 但两件事值得做(2026-10 调研 + codex 评审定的参数):
/// 1. **漏记**:某段间隔约等于典型周期的 2 或 3 倍,多半是中间那次没记(Li et al., JAMIA 2022
///    专门建模了记录依从性)。只**标成疑似**、不参与估计,不改写、不补造记录;基线不够时不猜。
/// 2. **给范围而不是一个日子**:按个人近期波动(MAD、P80)给 ±W 天,记录少时下限放宽。
///    这只是经验范围,没做过覆盖率校准,UI 上不能写成"90% 区间"或"准确率"。
///
/// 中心值用加权中位数(最近的权重 1,往前每个 ×0.85),对一两次异常比均值稳。
/// 不算排卵期/易孕期——这里不是医疗工具,页面写明不能用于避孕。
public enum CyclePrediction {
    // MARK: 参数(改之前先看单测)

    /// 候选间隔:最近 12 个,而且结束在最近 24 个月里。
    public static let candidateCount = 12
    public static let candidateMonths = 24
    /// 能参与估计的周期长度;范围外的照样展示,标「未用于预测」。
    public static let usableCycle = 15...90
    /// 最终取最近几个有效周期。
    public static let sampleCount = 6
    /// 越早的周期权重越低:第 i 个(0 = 最近)权重 0.85^i。
    public static let decay = 0.85
    /// 能参与估计的经期长度。
    public static let usablePeriod = 1...14
    /// 没有一次确认过结束日时的经期长度与范围。
    public static let defaultPeriodLength = 5
    public static let defaultPeriodSpread = 3
    /// 上一次开始离今天超过这么久,依据降为「较少」(中间多半漏记了)。
    public static let staleDays = 90
    /// 范围超过这么宽就不排提醒(提醒在范围下界前 2 天)。
    public static let maxRemindWindow = 7
    /// 提前几天提醒。
    public static let reminderDaysBefore = 2

    // MARK: 类型

    /// 一个日期范围:中心 + 上下界(都是当天 0 点,含首尾)。
    public struct Window: Equatable, Sendable {
        public var center: Date
        public var lower: Date
        public var upper: Date

        public init(center: Date, lower: Date, upper: Date) {
            self.center = center
            self.lower = lower
            self.upper = upper
        }
    }

    public enum Evidence: String, Equatable, Sendable {
        case low, medium, high
    }

    public enum ExclusionReason: Equatable, Sendable {
        /// 不在 15–90 天里。
        case outOfRange
        /// 约等于典型周期的 2 或 3 倍:中间多半漏记了一次。
        case likelySkipped
    }

    /// 两次开始之间的一段(开始日、长度、这段有没有被排除在估计之外)。
    public struct Interval: Equatable, Sendable {
        public var start: Date
        public var length: Int
        /// 这一段开头那次经期的天数——只有手记确认过结束日的才有(健康 App 的末日只是
        /// "最后一天有出血记录",不当确定的经期长度画)。给周期图用。
        public var periodLength: Int?
        public var excluded: ExclusionReason?
    }

    public enum Phase: Equatable, Sendable {
        /// 一次都没记过。
        case noRecords
        /// 经期中,今天是第 `day` 天。
        case inPeriod(day: Int)
        /// 点了开始、超过 10 天还没点结束:结束日期待确认(不替用户写结束日)。
        case endUnconfirmed(day: Int)
        /// 记录不够,还没有个人预测(有效周期不到 2 个)。
        case insufficient
        /// 离预测范围还早。
        case before
        /// 已经在预测范围里(可能这几天到来)。
        case inWindow
        /// 超出预测范围上界 `days` 天还没记开始(可能推迟,也可能漏记)。
        case late(days: Int)
    }

    public struct Result: Equatable, Sendable {
        public var phase: Phase
        /// 最近一次开始(含正在进行的这次)。
        public var lastStart: Date?
        /// 下一次开始的预测;记录不够时为 nil。
        public var nextStart: Window?
        /// 下一次结束的范围(开始范围 + 经期长度范围)。
        public var nextEnd: Window?
        /// 正在进行的这次预计哪天结束(经期中、结束待确认时有)。
        public var currentEnd: Window?
        /// 离下次预计开始(中心日)还有几天;0 = 今天。
        public var daysUntilStart: Int?
        /// 离这次预计结束(中心日)还有几天;0 = 今天。
        public var daysUntilEnd: Int?
        /// 典型周期 / 经期天数。
        public var cycleLength: Int?
        public var periodLength: Int
        /// 经期天数是按默认 5 天估的(没有一次确认过结束日)。
        public var periodLengthIsDefault: Bool
        /// 结束预测用了几次手记确认过的完整经期。
        public var endSamples: Int
        /// 开始预测 / 结束预测各自的依据。
        public var startEvidence: Evidence?
        public var endEvidence: Evidence
        /// 近期是否稳定;有效周期不到 3 个时为 nil。
        public var stable: Bool?
        /// 参与估计的有效周期数。
        public var validCycles: Int
        /// 近期周期的最短 / 最长(有效的那几个)。
        public var cycleRange: ClosedRange<Int>?
        /// 被当成疑似漏记、没用于估计的有几段(最近 12 段里)。
        public var skippedCount: Int
        /// 全部间隔,从近到远(历史列表、周期图用)。
        public var intervals: [Interval]
        /// 只有一段间隔时的那段长度(「上次周期 N 天」)。
        public var lastIntervalLength: Int?
        /// 能不能排经期提醒(依据不为「较少」、至少 3 个有效周期、范围不超过 7 天)。
        public var canRemind: Bool
    }

    // MARK: 计算

    /// `periods` 是合并好的全部经期(手记 + 健康 App,`CyclePlan.merge`)。
    public static func predict(_ periods: [CyclePlan.Period], today: Date,
                               calendar: Calendar = .current) -> Result {
        let todayStart = calendar.startOfDay(for: today)
        let past = periods
            .map { p -> CyclePlan.Period in
                var copy = p
                copy.start = calendar.startOfDay(for: p.start)
                copy.end = p.end.map { max(copy.start, calendar.startOfDay(for: $0)) }
                return copy
            }
            .filter { $0.start <= todayStart }
            .sorted { $0.start < $1.start }

        guard let last = past.last else {
            return Result(phase: .noRecords, lastStart: nil, nextStart: nil, nextEnd: nil, currentEnd: nil,
                          daysUntilStart: nil, daysUntilEnd: nil, cycleLength: nil,
                          periodLength: defaultPeriodLength, periodLengthIsDefault: true, endSamples: 0,
                          startEvidence: nil, endEvidence: .low, stable: nil, validCycles: 0,
                          cycleRange: nil, skippedCount: 0, intervals: [], lastIntervalLength: nil,
                          canRemind: false)
        }

        // ---- 间隔与排除 ----
        var intervals: [Interval] = []
        for (a, b) in zip(past, past.dropFirst()) {
            let length = days(from: a.start, to: b.start, calendar: calendar)
            let periodLength = a.fromHealth ? nil
                : a.end.map { days(from: a.start, to: $0, calendar: calendar) + 1 }
            intervals.append(Interval(start: a.start, length: length, periodLength: periodLength, excluded: nil))
        }
        let horizon = calendar.date(byAdding: .month, value: -candidateMonths, to: todayStart) ?? .distantPast
        var candidateIndexes = Array(intervals.indices.suffix(candidateCount)).filter {
            let end = calendar.date(byAdding: .day, value: intervals[$0].length, to: intervals[$0].start) ?? .distantPast
            return end >= horizon
        }
        for index in candidateIndexes where !usableCycle.contains(intervals[index].length) {
            intervals[index].excluded = .outOfRange
        }
        candidateIndexes = candidateIndexes.filter { intervals[$0].excluded == nil }
        // 漏记:先有一条可参考的个人基线(至少 3 段落在中位数附近),才去猜长的那几段是不是漏记。
        let candidateLengths = candidateIndexes.map { intervals[$0].length }
        if let m = median(candidateLengths.map(Double.init)) {
            let near = candidateLengths.filter { abs(Double($0) - m) <= max(3, 0.15 * m) }.count
            if near >= 3 {
                for index in candidateIndexes {
                    let length = Double(intervals[index].length)
                    guard length >= 1.7 * m else { continue }
                    let skipped = [2.0, 3.0].contains { k in abs(length / k - m) <= max(2, 0.10 * m) }
                    if skipped { intervals[index].excluded = .likelySkipped }
                }
            }
        }
        let skippedCount = candidateIndexes.filter { intervals[$0].excluded == .likelySkipped }.count
        // 「较充分」只看最近 6 个候选里的疑似漏记(更早的漏记不该拉低现在的依据)。
        let recentSkipped = intervals.indices.suffix(sampleCount)
            .filter { intervals[$0].excluded == .likelySkipped }.count
        // 最终样本:排除之后最近 6 段,从近到远。
        let valid = candidateIndexes.filter { intervals[$0].excluded == nil }
            .suffix(sampleCount).reversed().map { intervals[$0].length }

        // ---- 经期天数 ----
        // 只用手记确认过结束日、结束日不晚于今天的;健康 App 的末日只是"最后一天有出血记录",
        // 不当确认的结束。先按 1–14 天过滤,再取最近 6 次。一次都没有就按 5 ± 3 天。
        let periodLengths = past
            .filter { !$0.fromHealth }
            .compactMap { p -> Int? in
                guard let end = p.end, end <= todayStart else { return nil }
                return days(from: p.start, to: end, calendar: calendar) + 1
            }
            .filter { usablePeriod.contains($0) }
            .suffix(sampleCount).reversed().map { $0 }
        let periodLength: Int
        let periodSpread: Int
        if periodLengths.isEmpty {
            periodLength = defaultPeriodLength
            periodSpread = defaultPeriodSpread
        } else {
            periodLength = weightedMedian(periodLengths)
            let floor = periodLengths.count <= 2 ? 2 : 1
            periodSpread = spread(periodLengths, center: periodLength, floor: floor)
        }
        let endEvidence: Evidence = periodLengths.count >= 3 && periodSpread <= 2 ? .high
            : (periodLengths.isEmpty ? .low : .medium)

        // ---- 当前状态:在不在经期里 ----
        var phase: Phase?
        var currentEnd: Window?
        var daysUntilEnd: Int?
        let sinceStart = days(from: last.start, to: todayStart, calendar: calendar)
        let predictedEnd: Window = {
            let center = add(periodLength - 1, to: last.start, calendar: calendar)
            let lower = add(max(1, periodLength - periodSpread) - 1, to: last.start, calendar: calendar)
            let upper = add(periodLength + periodSpread - 1, to: last.start, calendar: calendar)
            return Window(center: center, lower: min(lower, center), upper: max(upper, center))
        }()
        if !last.fromHealth {
            if let end = last.end {
                // 手记确认过结束日:今天还没过结束日就是经期中,结束日就是它。
                if todayStart <= end {
                    phase = .inPeriod(day: sinceStart + 1)
                    currentEnd = Window(center: end, lower: end, upper: end)
                }
            } else if todayStart <= predictedEnd.upper {
                // 点了开始、还没点结束,还在预计结束范围里。
                phase = .inPeriod(day: sinceStart + 1)
                currentEnd = predictedEnd
            } else {
                // 过了预计结束范围还没点结束:结束日期待确认(不替用户写结束日)。预计结束范围
                // 照样给出来(补记时判断某天在不在这次经期里要用,不能因为进了待确认就缩回去)。
                phase = .endUnconfirmed(day: sinceStart + 1)
                currentEnd = predictedEnd
            }
        } else if let observed = last.end,
                  todayStart <= add(1, to: observed, calendar: calendar), todayStart <= predictedEnd.upper {
            // 健康 App 的:最后一天有出血记录是今天或昨天、又还在预计结束范围里,当作还在经期中。
            phase = .inPeriod(day: sinceStart + 1)
            currentEnd = predictedEnd
        }
        if case .inPeriod = phase {
            daysUntilEnd = currentEnd.map { days(from: todayStart, to: $0.center, calendar: calendar) }
        }

        // ---- 下一次开始 ----
        var nextStart: Window?
        var nextEnd: Window?
        var startEvidence: Evidence?
        var cycleLength: Int?
        var stable: Bool?
        var canRemind = false
        if valid.count >= 2 {
            let c = weightedMedian(valid)
            cycleLength = c
            let floor = valid.count == 2 ? 7 : (valid.count <= 4 ? 4 : 2)
            let w = spread(valid, center: c, floor: floor)
            let center = add(c, to: last.start, calendar: calendar)
            let lower = max(add(1, to: last.start, calendar: calendar), add(-w, to: center, calendar: calendar))
            let upper = add(w, to: center, calendar: calendar)
            nextStart = Window(center: center, lower: lower, upper: upper)
            let endLower = max(1, periodLength - periodSpread)
            let endUpper = periodLength + periodSpread
            nextEnd = Window(center: add(periodLength - 1, to: center, calendar: calendar),
                             lower: add(endLower - 1, to: lower, calendar: calendar),
                             upper: add(endUpper - 1, to: upper, calendar: calendar))

            if valid.count >= 3 {
                let m = median(valid.map(Double.init)) ?? Double(c)
                let mad = median(valid.map { abs(Double($0) - m) }) ?? 0
                stable = mad <= 2 && (valid.max()! - valid.min()!) <= 7
            }
            let stale = sinceStart > staleDays
            if valid.count == 2 || w > 7 || stale {
                startEvidence = .low
            } else if valid.count >= 5, w <= 4, recentSkipped <= 1 {
                startEvidence = .high
            } else {
                startEvidence = .medium
            }
            canRemind = valid.count >= 3 && startEvidence != .low && w <= maxRemindWindow
        }

        if phase == nil {
            if let nextStart {
                if todayStart > nextStart.upper {
                    phase = .late(days: days(from: nextStart.upper, to: todayStart, calendar: calendar))
                } else if todayStart >= nextStart.lower {
                    phase = .inWindow
                } else {
                    phase = .before
                }
            } else {
                phase = .insufficient
            }
        }

        return Result(
            phase: phase ?? .insufficient, lastStart: last.start, nextStart: nextStart, nextEnd: nextEnd,
            currentEnd: currentEnd,
            daysUntilStart: nextStart.map { days(from: todayStart, to: $0.center, calendar: calendar) },
            daysUntilEnd: daysUntilEnd, cycleLength: cycleLength, periodLength: periodLength,
            periodLengthIsDefault: periodLengths.isEmpty, endSamples: periodLengths.count,
            startEvidence: startEvidence, endEvidence: endEvidence,
            stable: stable, validCycles: valid.count,
            cycleRange: valid.isEmpty ? nil : valid.min()!...valid.max()!,
            skippedCount: skippedCount, intervals: intervals.reversed(),
            lastIntervalLength: intervals.count == 1 ? intervals[0].length : nil,
            canRemind: canRemind)
    }

    /// 经期提醒:下次开始范围的下界前 `reminderDaysBefore` 天的 `time`("HH:MM")。
    /// 不满足 `canRemind`、时刻已过都返回 nil(不追补、不每天催)。
    public static func reminderDate(_ result: Result, time: String, now: Date,
                                    calendar: Calendar = .current) -> Date? {
        guard result.canRemind, let next = result.nextStart,
              let day = calendar.date(byAdding: .day, value: -reminderDaysBefore, to: next.lower) else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]),
              let fire = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day),
              fire > now else { return nil }
        return fire
    }

    // MARK: - 统计小工具(internal,单测直接测)

    /// 加权中位数:`values` 从近到远排,第 i 个权重 `decay^i`;按数值排序累加权重,
    /// 到总权重一半的那个值。
    static func weightedMedian(_ values: [Int]) -> Int {
        let weighted = values.enumerated().map { (value: $0.element, weight: pow(decay, Double($0.offset))) }
        let total = weighted.reduce(0) { $0 + $1.weight }
        var acc = 0.0
        for item in weighted.sorted(by: { $0.value < $1.value }) {
            acc += item.weight
            if acc >= total / 2 - 1e-9 { return item.value }
        }
        return values.first ?? 0
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 范围半宽 W = ceil(max(下限, 2 × 1.4826 × MAD, P80(|Li − 中心|)))。P80 用最近秩法。
    static func spread(_ values: [Int], center: Int, floor: Int) -> Int {
        let doubles = values.map(Double.init)
        let m = median(doubles) ?? Double(center)
        let mad = median(doubles.map { abs($0 - m) }) ?? 0
        let deviations = doubles.map { abs($0 - Double(center)) }.sorted()
        let rank = max(1, Int((0.8 * Double(deviations.count)).rounded(.up)))
        let p80 = deviations.isEmpty ? 0 : deviations[min(rank, deviations.count) - 1]
        return Int(max(Double(floor), 2 * 1.4826 * mad, p80).rounded(.up))
    }

    private static func days(from a: Date, to b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private static func add(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}
