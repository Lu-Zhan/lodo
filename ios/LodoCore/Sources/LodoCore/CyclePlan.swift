import Foundation

/// 健康页「经期」的纯逻辑(单测 `CyclePlanTests`,不 import HealthKit)。
///
/// 数据有两路:lodo 里手记的经期(`PeriodRecord`)和健康 App 里的经期流量记录(一天一条)。
/// 健康 App 的按天连成一段段经期,和手记的合并时**手记优先**(两段有重叠就只留手记那段)。
/// 预测只做最朴素的那种:最近 6 个周期(开始日到下一次开始日)的平均长度往后推,
/// 不算排卵期/易孕期——这里不是医疗工具,估错了代价不对等。
public enum CyclePlan {
    /// 默认周期长度:只记过一次经期、算不出平均时用它估,UI 上写明「按 28 天估算」。
    public static let defaultCycleLength = 28
    public static let defaultPeriodLength = 5
    /// 只认这个范围内的周期长度;更短/更长的多半是漏记或记重了,不拿来算平均。
    public static let plausibleCycle = 15...60
    /// 手记了「开始」没记「结束」:超过这么多天还没结束,就按平均经期长度算它已经结束。
    public static let openPeriodLimit = 10
    /// 平均只看最近几个周期。
    public static let averagedCycles = 6

    public enum Source: Equatable { case manual(UUID), health }

    public struct Period: Equatable {
        /// 开始那天(0 点)。
        public var start: Date
        /// 结束那天(0 点,含当天);nil = 手记的还没结束。
        public var end: Date?
        public var source: Source

        public init(start: Date, end: Date?, source: Source) {
            self.start = start
            self.end = end
            self.source = source
        }

        public var fromHealth: Bool { source == .health }
    }

    // MARK: - 合并

    /// 健康 App 的经期流量日 → 一段段经期:相邻两天间隔不超过 2 天(中间漏记一天)算同一段。
    public static func periods(fromFlowDays days: [Date], calendar: Calendar = .current) -> [Period] {
        let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
        var result: [Period] = []
        for day in sorted {
            if var last = result.last, let end = last.end,
               let gap = calendar.dateComponents([.day], from: end, to: day).day, gap <= 2 {
                last.end = day
                result[result.count - 1] = last
            } else {
                result.append(Period(start: day, end: day, source: .health))
            }
        }
        return result
    }

    /// 手记 + 健康 App,按开始日从早到晚。两段重叠时手记那段留下、健康那段丢掉。
    public static func merge(manual: [Period], health: [Period], today: Date,
                             calendar: Calendar = .current) -> [Period] {
        // 同一天开始的手记只留一条:有结束日的优先(记得更全);一样完整就按来源 uuid 固定挑一条,
        // 不受查询顺序影响(不然结束日和预测会跟着取数顺序变)。
        func key(_ period: Period) -> String {
            if case .manual(let id) = period.source { return id.uuidString }
            return ""
        }
        var byStart: [Date: Period] = [:]
        for period in manual.map({ normalized($0, calendar: calendar) }) {
            guard let kept = byStart[period.start] else {
                byStart[period.start] = period
                continue
            }
            let better = (kept.end == nil) != (period.end == nil)
                ? period.end != nil
                : key(period) < key(kept)
            if better { byStart[period.start] = period }
        }
        let manualDays = byStart.values.sorted { $0.start < $1.start }
        var result = manualDays
        for period in health {
            let candidate = normalized(period, calendar: calendar)
            let overlaps = manualDays.contains { m in
                let mEnd = effectiveEnd(m, today: today, calendar: calendar)
                let cEnd = effectiveEnd(candidate, today: today, calendar: calendar)
                return candidate.start <= mEnd && m.start <= cEnd
            }
            if !overlaps { result.append(candidate) }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func normalized(_ period: Period, calendar: Calendar) -> Period {
        var copy = period
        copy.start = calendar.startOfDay(for: period.start)
        copy.end = period.end.map { max(copy.start, calendar.startOfDay(for: $0)) }
        return copy
    }

    /// 这段手记还算"开着"(点了开始、还没点结束,而且没超过 `openPeriodLimit` 天——
    /// 超过的按自动收尾处理,不该再挡着记下一次的「开始」)。
    public static func isOpen(start: Date, end: Date?, today: Date, calendar: Calendar = .current) -> Bool {
        guard end == nil else { return false }
        let todayStart = calendar.startOfDay(for: today)
        let startDay = calendar.startOfDay(for: start)
        guard startDay <= todayStart else { return false }
        let days = calendar.dateComponents([.day], from: startDay, to: todayStart).day ?? 0
        return days < openPeriodLimit
    }

    /// 一段经期实际算到哪天:有结束日就是结束日;没有的话最多算到今天,
    /// 超过 `openPeriodLimit` 天按平均经期长度收尾。
    public static func effectiveEnd(_ period: Period, today: Date, averagePeriod: Int = defaultPeriodLength,
                                    calendar: Calendar = .current) -> Date {
        if let end = period.end { return end }
        let todayStart = calendar.startOfDay(for: today)
        let days = calendar.dateComponents([.day], from: period.start, to: todayStart).day ?? 0
        if days >= openPeriodLimit {
            return calendar.date(byAdding: .day, value: max(averagePeriod, 1) - 1, to: period.start)
                ?? period.start
        }
        return max(todayStart, period.start)
    }

    // MARK: - 统计与预测

    public struct Summary: Equatable {
        /// 平均周期长度(天);nil = 记录不够,预测用的是默认 28 天。
        public var averageCycle: Int?
        /// 平均经期长度(天);nil = 没有记过结束日。
        public var averagePeriod: Int?
        /// 最近几个周期里最长最短差几天(周期规律程度);少于 3 个周期时为 nil。
        public var variation: Int?
        public var lastStart: Date?
        /// 今天在经期里:第几天(1 起)。
        public var periodDay: Int?
        /// 今天是这个周期的第几天(1 = 最近一次开始那天)。
        public var cycleDay: Int?
        /// 预计下一次开始的日子。
        public var nextStart: Date?
        /// 离预计开始还有几天(今天 = 0);已经过了预计日还没来时为负数。
        public var daysUntilNext: Int?
        /// 预测是按默认 28 天估的(只记过一次)。
        public var estimatedFromDefault: Bool
        /// 最近的几个周期(开始日, 长度),从近到远,给历史列表用。
        public var cycles: [(start: Date, length: Int)]

        public static func == (a: Summary, b: Summary) -> Bool {
            a.averageCycle == b.averageCycle && a.averagePeriod == b.averagePeriod
                && a.variation == b.variation && a.lastStart == b.lastStart
                && a.periodDay == b.periodDay && a.cycleDay == b.cycleDay
                && a.nextStart == b.nextStart && a.daysUntilNext == b.daysUntilNext
                && a.estimatedFromDefault == b.estimatedFromDefault
                && a.cycles.map(\.start) == b.cycles.map(\.start)
                && a.cycles.map(\.length) == b.cycles.map(\.length)
        }
    }

    public static func summary(_ periods: [Period], today: Date, calendar: Calendar = .current) -> Summary {
        let sorted = periods.sorted { $0.start < $1.start }
        let todayStart = calendar.startOfDay(for: today)
        guard let last = sorted.last(where: { $0.start <= todayStart }) else {
            return Summary(averageCycle: nil, averagePeriod: nil, variation: nil, lastStart: nil,
                           periodDay: nil, cycleDay: nil, nextStart: nil, daysUntilNext: nil,
                           estimatedFromDefault: false, cycles: [])
        }
        let past = sorted.filter { $0.start <= todayStart }

        var cycles: [(start: Date, length: Int)] = []
        for (a, b) in zip(past, past.dropFirst()) {
            let length = calendar.dateComponents([.day], from: a.start, to: b.start).day ?? 0
            cycles.append((a.start, length))
        }
        let recent = cycles.filter { plausibleCycle.contains($0.length) }.suffix(averagedCycles)
        let averageCycle = recent.isEmpty ? nil
            : Int((Double(recent.map(\.length).reduce(0, +)) / Double(recent.count)).rounded())
        let variation = recent.count >= 3
            ? (recent.map(\.length).max() ?? 0) - (recent.map(\.length).min() ?? 0) : nil

        let closed = past.compactMap { period -> Int? in
            guard let end = period.end else { return nil }
            return (calendar.dateComponents([.day], from: period.start, to: end).day ?? 0) + 1
        }.suffix(averagedCycles)
        let averagePeriod = closed.isEmpty ? nil
            : Int((Double(closed.reduce(0, +)) / Double(closed.count)).rounded())

        let lastEnd = effectiveEnd(last, today: today, averagePeriod: averagePeriod ?? defaultPeriodLength,
                                   calendar: calendar)
        let sinceStart = calendar.dateComponents([.day], from: last.start, to: todayStart).day ?? 0
        let periodDay = todayStart <= lastEnd ? sinceStart + 1 : nil

        let length = averageCycle ?? defaultCycleLength
        let nextStart = calendar.date(byAdding: .day, value: length, to: last.start)
        let daysUntil = nextStart.flatMap { calendar.dateComponents([.day], from: todayStart, to: $0).day }

        return Summary(averageCycle: averageCycle, averagePeriod: averagePeriod, variation: variation,
                       lastStart: last.start, periodDay: periodDay, cycleDay: sinceStart + 1,
                       nextStart: nextStart, daysUntilNext: daysUntil,
                       estimatedFromDefault: averageCycle == nil,
                       cycles: cycles.reversed())
    }

    /// 经期提醒:预计开始前 `daysBefore` 天的 `time`("HH:MM")。预计日已过、
    /// 只按默认 28 天估的,都不提醒(估不准的提醒比不提醒更烦)。
    public static func reminderDate(_ summary: Summary, daysBefore: Int, time: String, now: Date,
                                    calendar: Calendar = .current) -> Date? {
        guard !summary.estimatedFromDefault, let next = summary.nextStart,
              let day = calendar.date(byAdding: .day, value: -daysBefore, to: next) else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let fire = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day),
              fire > now else { return nil }
        return fire
    }

    // MARK: - 默认开关

    /// 设置里「经期记录」那一项:跟随健康 App 里的性别 / 开 / 关。存储值别改。
    public enum Preference: String, CaseIterable {
        case auto = ""
        case on
        case off
    }

    /// 健康 App 里的性别(只认这三种,读不到 = unknown)。存储值别改。
    public enum Sex: String {
        case female, male, other, unknown = ""
    }

    /// 自动:健康 App 里是女性就开,其余(男性、其他、读不到)都关。
    public static func isEnabled(_ preference: Preference, sex: Sex) -> Bool {
        switch preference {
        case .on: return true
        case .off: return false
        case .auto: return sex == .female
        }
    }
}
