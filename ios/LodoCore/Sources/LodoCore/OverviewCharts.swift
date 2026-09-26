import Foundation

/// 总览页圆环 / 图表类 widget 的纯计算(`OverviewChartsTests`)。
/// 和 `OverviewTime` 一样只做数,不碰 SwiftUI / HealthKit。
public enum OverviewCharts {

    /// 本周(周一起头,同 Scheduler 的 0=周一口径)每天完成了几件。
    /// 恒返回 7 个,没完成的日子是 0——柱状图要把空着的那几天也画出来。
    public static func weeklyDone(doneDates: [Date], now: Date,
                                  calendar: Calendar = .current) -> [OverviewDayCount] {
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: today) else { return [] }
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        var counts = [Date: Int]()
        for date in doneDates {
            let day = calendar.startOfDay(for: date)
            if day >= monday, let last = days.last, day <= last { counts[day, default: 0] += 1 }
        }
        return days.enumerated().map { index, day in
            OverviewDayCount(weekdayIndex: index, date: day, count: counts[day] ?? 0, isToday: day == today)
        }
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
    public var id: Int { weekdayIndex }
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
