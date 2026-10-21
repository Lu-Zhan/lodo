import Foundation

/// Watch 首页只看"今天":今天要做的任务、今天放进收集的事,和今天记下的记忆。
/// 判断写成值函数(不碰 SwiftData),离线单测 `WatchTodayTests`。
public enum WatchToday {
    /// 一条未完成的任务今天该不该出现在手表首页。
    /// - 收集里的事没有截止时间,按"今天放进来的"算(createdAt 在今天)。
    /// - 其余只看原定时间 `remindAt`:今天到期的,加上以前到期还没做完的(逾期仍是今天要做的事)。
    ///   **不看 `nextRemindAt`**——它随提醒响过、稍等顺延,拿它判断会让同一件事在首页时有时无
    ///   (23:50 响一次顺延到明天 00:05 就从今天消失了)。重复事项的 remindAt 指向下一次发生,
    ///   今天这次完成后顺延到明天,自然就不显示了。
    public static func includesTask(isInbox: Bool, createdAt: Date, remindAt: Date,
                                    now: Date, calendar: Calendar = .current) -> Bool {
        if isInbox { return calendar.isDate(createdAt, inSameDayAs: now) }
        return remindAt < nextDayStart(after: now, calendar: calendar)
    }

    /// 一条记忆今天该不该出现:今天记下的,口径同手机记忆列表——人脉、资产不显示;
    /// 另外体检、体重秤报告、健康资料不在手表首页摊开(抬腕就能被旁人看到)。
    public static func includesMemory(createdAt: Date, tags: [String],
                                      now: Date, calendar: Calendar = .current) -> Bool {
        guard calendar.isDate(createdAt, inSameDayAs: now) else { return false }
        return tags.allSatisfy { !excludedMemoryTags.contains($0) }
    }

    /// 下一个 0 点(按日历运算,不是加 86400 秒——夏令时那天不是 24 小时)。
    public static func nextDayStart(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    static let excludedMemoryTags: Set<String> = [
        MemoryItem.contactTagName, MemoryItem.assetTagName, MemoryItem.healthTagName,
        MemoryItem.checkupTagName, MemoryItem.weightReportTagName,
    ]
}
