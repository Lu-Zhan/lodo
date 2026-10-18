import Foundation

/// 总览页圆环 / 图表类 widget 的纯计算(`OverviewChartsTests`)。
/// 和 `OverviewTime` 一样只做数,不碰 SwiftUI / HealthKit。
public enum OverviewCharts {

    /// 本周(周一起头,同 Scheduler 的 0=周一口径)每天完成了几件。
    /// 恒返回 7 个,没完成的日子是 0——柱状图要把空着的那几天也画出来;
    /// 今天之后的日子标 `isFuture`,图上和"已经过去、一件没做"的 0 分开画。
    public static func weeklyDone(doneDates: [Date], now: Date,
                                  calendar: Calendar = .current) -> [OverviewDayCount] {
        recentWeeks(doneDates: doneDates, weeks: 1, now: now, calendar: calendar)
    }

    /// 最近 `weeks` 周(含本周,周一起头)每天完成了几件,按时间先后排,
    /// 共 `weeks × 7` 个;`weekOffset` 本周是 0、上周 -1……
    public static func recentWeeks(doneDates: [Date], weeks: Int, now: Date,
                                   calendar: Calendar = .current) -> [OverviewDayCount] {
        guard weeks > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: today),
              let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: monday) else { return [] }
        let days = (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        var counts = [Date: Int]()
        for date in doneDates {
            let day = calendar.startOfDay(for: date)
            if day >= first, let last = days.last, day <= last { counts[day, default: 0] += 1 }
        }
        return days.enumerated().map { index, day in
            OverviewDayCount(weekdayIndex: index % 7, date: day, count: counts[day] ?? 0,
                             isToday: day == today, isFuture: day > today,
                             weekOffset: index / 7 - (weeks - 1))
        }
    }

    /// 本周到今天为止完成的件数,和上周同一段(周一到上周的同一个星期几)比。
    /// 拿整个上周比,周一早上永远是"比上周少很多"。
    public static func weekToDate(doneDates: [Date], now: Date,
                                  calendar: Calendar = .current) -> (thisWeek: Int, lastWeek: Int) {
        let days = recentWeeks(doneDates: doneDates, weeks: 2, now: now, calendar: calendar)
        guard let todayIndex = days.firstIndex(where: \.isToday) else { return (0, 0) }
        let weekday = todayIndex - 7
        let thisWeek = days[7...todayIndex].reduce(0) { $0 + $1.count }
        let lastWeek = days[0...weekday].reduce(0) { $0 + $1.count }
        return (thisWeek, lastWeek)
    }

    /// 最近 `days` 天的日值,缺的日子补 nil(图上留空,不画成 0——"没戴表"不是"没走路")。
    /// `points` 是 (那天任意时刻, 值),按天对齐。最后一个是今天。
    public static func recentDays(points: [(date: Date, value: Double)], days: Int = 7, now: Date,
                                  calendar: Calendar = .current) -> [OverviewDayValue] {
        let today = calendar.startOfDay(for: now)
        var byDay = [Date: Double]()
        for point in points { byDay[calendar.startOfDay(for: point.date)] = point.value }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return OverviewDayValue(date: day, value: byDay[day], isToday: offset == 0)
        }
    }

    /// 圆环进度:值 / 目标。不封顶在 1——超额完成的那一圈要能画出第二圈的起头
    /// (系统健身记录也是这样),由视图决定怎么画;负数和目标 ≤0 当 0。
    public static func ringProgress(value: Double?, goal: Double) -> Double {
        guard let value, goal > 0, value > 0 else { return 0 }
        return value / goal
    }

    /// 今日任务完成度:完成 / (完成 + 还剩)。今天一件任务都没有时是 nil
    /// ——"没有任务"和"一件没做"要区分开,前者圆环不该是空的红圈。
    public static func taskCompletion(done: Int, remaining: Int) -> Double? {
        let total = done + remaining
        guard total > 0 else { return nil }
        return Double(done) / Double(total)
    }
}

public struct OverviewDayCount: Equatable, Sendable, Identifiable {
    /// 0=周一 … 6=周日。
    public let weekdayIndex: Int
    public let date: Date
    public let count: Int
    public let isToday: Bool
    /// 今天之后的日子(本周还没到的那几天)。
    public var isFuture: Bool = false
    /// 本周 0、上周 -1……
    public var weekOffset: Int = 0
    public var id: Date { date }
}

public struct OverviewDayValue: Equatable, Sendable, Identifiable {
    public let date: Date
    public let value: Double?
    public let isToday: Bool
    public var id: Date { date }
}

/// 活动圆环的三个目标。没有接系统健身记录的"目标"设置(那要另外的授权和 API),
/// 先用常见的默认值:活动 500 千卡、锻炼 30 分钟、步数 8000。
public enum ActivityRingGoal {
    public static let activeEnergy: Double = 500
    public static let exerciseMinutes: Double = 30
    public static let steps: Double = 8000
}

// MARK: - 积压提醒

/// 「积压提醒」:原定提醒时间已经过了、还没完成的任务,按拖了多久分四档。
/// 用 `remindAt`(原定时间)而不是 `nextRemindAt`(下一次响铃)——稍等过的
/// 事项下一次响铃可能还没到,但它确实已经拖着了。
public struct OverviewBacklog: Equatable, Sendable {
    public enum Bucket: Int, CaseIterable, Sendable {
        /// 今天原定、已经过点。
        case today
        /// 1–3 天前。
        case days1to3
        /// 4–7 天前。
        case days4to7
        /// 更早。
        case older
    }

    /// 和 `Bucket.allCases` 同序。
    public let counts: [Int]
    /// 拖得最久的那件拖了几天(今天原定的算 0);没有积压时 nil。
    public let oldestDays: Int?
    /// 拖得最久的那件的下标(调用方传进来的顺序)。
    public let oldestIndex: Int?

    public var total: Int { counts.reduce(0, +) }

    public func count(_ bucket: Bucket) -> Int { counts[bucket.rawValue] }

    public static func build(remindAts: [Date], now: Date,
                             calendar: Calendar = .current) -> OverviewBacklog {
        var counts = [0, 0, 0, 0]
        var oldest: (days: Int, index: Int)?
        for (index, remindAt) in remindAts.enumerated() where remindAt <= now {
            let days = -OverviewTime.daysUntil(remindAt, from: now, calendar: calendar)
            let bucket: Bucket = days <= 0 ? .today : days <= 3 ? .days1to3 : days <= 7 ? .days4to7 : .older
            counts[bucket.rawValue] += 1
            if oldest == nil || days > oldest!.days { oldest = (days, index) }
        }
        return OverviewBacklog(counts: counts, oldestDays: oldest.map { max(0, $0.days) },
                               oldestIndex: oldest?.index)
    }
}

extension OverviewCharts {

    /// 今日进度的口径:今天完成的 / (今天完成的 + 原定今天、还没做的)。
    /// 以前拖下来的不算进分母——它们在「积压提醒」里看;否则把积压的事稍等到
    /// 明天,百分比就会凭空上涨。`pendingRemindAts` 是所有未完成任务的原定时间。
    public static func todayPlan(doneToday: Int, pendingRemindAts: [Date], now: Date,
                                 calendar: Calendar = .current) -> (done: Int, remaining: Int) {
        let remaining = pendingRemindAts.filter { calendar.isDate($0, inSameDayAs: now) }.count
        return (doneToday, remaining)
    }

    /// 圆环图例里的百分比:超额完成照写(「250%」),不封顶。
    public static func percentText(_ progress: Double) -> String {
        "\(Int((progress * 100).rounded()))%"
    }

    /// 接下来 `hours` 个整点的温度和 AQI,对到同一条时间轴上(从当前整点起)。
    /// 某一边缺那个小时就是 nil,图上留空。
    public static func nextHours(temperatures: [(date: Date, value: Double)],
                                 aqi: [(date: Date, value: Int)],
                                 now: Date, hours: Int = 12,
                                 calendar: Calendar = .current) -> [OverviewHourPoint] {
        guard let start = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        func hourKey(_ date: Date) -> Date { calendar.dateInterval(of: .hour, for: date)?.start ?? date }
        var temps = [Date: Double]()
        for point in temperatures { temps[hourKey(point.date)] = point.value }
        var aqis = [Date: Int]()
        for point in aqi { aqis[hourKey(point.date)] = point.value }
        let points = (0..<hours).compactMap { offset -> OverviewHourPoint? in
            guard let hour = calendar.date(byAdding: .hour, value: offset, to: start) else { return nil }
            return OverviewHourPoint(date: hour, temperature: temps[hour], aqi: aqis[hour])
        }
        return points.contains { $0.temperature != nil || $0.aqi != nil } ? points : []
    }

    /// 稳定的内容指纹(FNV-1a)。AI 那几段按"当天 + 输入内容"缓存:任务完成了、
    /// 新收藏了,指纹变了就该重新要一份。不用 `Hasher`——它每次进程启动换种子。
    public static func fingerprint(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}

public struct OverviewHourPoint: Equatable, Sendable, Identifiable {
    public let date: Date
    public let temperature: Double?
    public let aqi: Int?
    public var id: Date { date }
}
