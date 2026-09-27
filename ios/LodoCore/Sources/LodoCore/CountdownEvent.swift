import Foundation
import SwiftData

/// 倒数日:一件有开始时间(可选结束时间)的事——考试、搬家、演唱会、假期。
/// 页面上显示"还有几天开始 / 已经开始几天 / 还有几天结束 / 结束几天了",开始和
/// 结束各自可以挂多个提醒(提前多久提醒)。
///
/// 和任务的分工:任务是"要去做的事",到点纠缠着问你做完没有;倒数日是"要到来的
/// 日子",只看离它还有多久,不需要完成。两边不互相转换。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class CountdownEvent {
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var startDate: Date = Date.now
    /// 结束时间;nil = 只有一个日子(生日、考试那天)。
    public var endDate: Date?
    /// 全天:只看日期,不看几点。提醒按「设置 → 提醒 → 全天提醒时间」那个时刻算。
    public var allDay: Bool = true
    public var notes: String = ""
    /// 开始/结束前多少分钟提醒,可以多个;0 = 准时。
    public var startReminders: [Int] = []
    public var endReminders: [Int] = []
    /// 显示在锁屏「倒数日」小组件上(最多 3 件,见 `CountdownPlan.widgetLimit`)。
    public var showInWidget: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), title: String = "", startDate: Date = .now,
                endDate: Date? = nil, allDay: Bool = true, notes: String = "",
                startReminders: [Int] = [], endReminders: [Int] = [],
                showInWidget: Bool = false, createdAt: Date = .now) {
        self.uuid = uuid
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.allDay = allDay
        self.notes = notes
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
        self.createdAt = createdAt
    }

    /// 值快照,交给纯逻辑计算。
    public var entry: CountdownEntry {
        CountdownEntry(id: uuid, title: title, start: startDate, end: endDate, allDay: allDay,
                       startReminders: startReminders, endReminders: endReminders,
                       showInWidget: showInWidget)
    }
}

/// 倒数日的值快照(由 `CountdownEvent` 转出来),`CountdownPlan` 只认这个。
public struct CountdownEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let start: Date
    public let end: Date?
    public let allDay: Bool
    public let startReminders: [Int]
    public let endReminders: [Int]
    public let showInWidget: Bool

    public init(id: UUID = UUID(), title: String, start: Date, end: Date? = nil,
                allDay: Bool = true, startReminders: [Int] = [], endReminders: [Int] = [],
                showInWidget: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
    }
}

/// 离某个节点多久:哪个节点、差几天,同一天之内有具体时刻的再给分钟数。
public struct CountdownSpan: Equatable, Sendable {
    public enum Milestone: Equatable, Sendable {
        /// 还没开始,离开始还有多久。
        case untilStart
        /// 已经开始多久(进行中,或只有一个日子、那天已经过去)。
        case sinceStart
        /// 进行中,离结束还有多久。
        case untilEnd
        /// 已经结束多久。
        case sinceEnd
    }

    public let milestone: Milestone
    /// 按日历天数算的差(非负)。今天 = 0。
    public let days: Int
    /// 只在**有具体时刻**(非全天)且就在今天(days == 0)时给:还差/已过几分钟(非负)。
    public let minutes: Int?

    public init(milestone: Milestone, days: Int, minutes: Int? = nil) {
        self.milestone = milestone
        self.days = days
        self.minutes = minutes
    }
}

/// 倒数日的一次提醒。
public struct CountdownReminder: Equatable, Sendable {
    public let eventID: UUID
    public let title: String
    public let fireDate: Date
    /// 这次提醒对的是结束(false = 开始)。
    public let isEnd: Bool
    /// 提前多少分钟(0 = 准时)。
    public let offsetMinutes: Int

    public init(eventID: UUID, title: String, fireDate: Date, isEnd: Bool, offsetMinutes: Int) {
        self.eventID = eventID
        self.title = title
        self.fireDate = fireDate
        self.isEnd = isEnd
        self.offsetMinutes = offsetMinutes
    }
}

public enum CountdownPlan {
    /// 锁屏小组件最多显示几件(accessoryRectangular 只放得下三行)。
    public static let widgetLimit = 3

    /// 提醒选项:准时、5/15/30 分钟、1/2 小时、1/2 天、1 周前。
    public static let reminderPresets = [0, 5, 15, 30, 60, 120, 1440, 2880, 10080]

    /// 一件事现在处在哪一段、离各个节点多久。返回的第一个是"主要的那一个"
    /// (列表行大字、小组件那一行):没开始 → 离开始;进行中 → 离结束;
    /// 只有一个日子且过了 → 已经过去多久;结束了 → 结束多久。
    /// 进行中时第二个是"已经开始多久"。
    ///
    /// 全天的事按日子算:开始那天 0 点就算开始了,结束那天整天都还算进行中,
    /// 第二天 0 点才算结束。有时刻的按时刻算。
    public static func spans(_ entry: CountdownEntry, now: Date,
                             calendar: Calendar = .current) -> [CountdownSpan] {
        let today = calendar.startOfDay(for: now)
        let startMoment = entry.allDay ? calendar.startOfDay(for: entry.start) : entry.start
        let endMoment: Date? = entry.end.map { end in
            entry.allDay
                ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
                    ?? end
                : end
        }

        func dayDiff(_ date: Date) -> Int {
            abs(calendar.dateComponents([.day], from: today,
                                        to: calendar.startOfDay(for: date)).day ?? 0)
        }
        func span(_ milestone: CountdownSpan.Milestone, _ moment: Date,
                  dayOf: Date) -> CountdownSpan {
            let days = dayDiff(dayOf)
            let minutes = (!entry.allDay && days == 0)
                ? Int((abs(moment.timeIntervalSince(now)) / 60).rounded(.down)) : nil
            return CountdownSpan(milestone: milestone, days: days, minutes: minutes)
        }

        if now < startMoment {
            return [span(.untilStart, startMoment, dayOf: entry.start)]
        }
        guard let endMoment, let end = entry.end else {
            return [span(.sinceStart, startMoment, dayOf: entry.start)]
        }
        if now < endMoment {
            return [span(.untilEnd, endMoment, dayOf: end),
                    span(.sinceStart, startMoment, dayOf: entry.start)]
        }
        // 全天的事结束日是"那天整天",过去多少天从结束那天算起。
        return [span(.sinceEnd, endMoment, dayOf: end)]
    }

    public static func primary(_ entry: CountdownEntry, now: Date,
                               calendar: Calendar = .current) -> CountdownSpan {
        spans(entry, now: now, calendar: calendar)[0]
    }

    /// 已经整个结束了(只有一个日子的,那天过去了也算)。
    public static func isPast(_ entry: CountdownEntry, now: Date,
                              calendar: Calendar = .current) -> Bool {
        let span = primary(entry, now: now, calendar: calendar)
        switch span.milestone {
        case .sinceEnd: return true
        // 只有一个日子的全天事,当天还不算过去——"就是今天"。
        case .sinceStart: return !(entry.allDay && span.days == 0)
        case .untilStart, .untilEnd: return false
        }
    }

    /// 页面排序:还没过去的在前,按"下一个节点"从近到远;过去了的在后,最近
    /// 过去的在前。
    public static func sorted(_ entries: [CountdownEntry], now: Date,
                              calendar: Calendar = .current) -> [CountdownEntry] {
        func nextMoment(_ entry: CountdownEntry) -> Date {
            if now < entry.start { return entry.start }
            return entry.end ?? entry.start
        }
        func lastMoment(_ entry: CountdownEntry) -> Date { entry.end ?? entry.start }
        let upcoming = entries.filter { !isPast($0, now: now, calendar: calendar) }
            .sorted { nextMoment($0) < nextMoment($1) }
        let past = entries.filter { isPast($0, now: now, calendar: calendar) }
            .sorted { lastMoment($0) > lastMoment($1) }
        return upcoming + past
    }

    /// 小组件上显示哪几件:勾了"显示在小组件"的,按页面同样的顺序取前 3 件。
    public static func widgetEntries(_ entries: [CountdownEntry], now: Date,
                                     calendar: Calendar = .current) -> [CountdownEntry] {
        Array(sorted(entries.filter(\.showInWidget), now: now, calendar: calendar)
            .prefix(widgetLimit))
    }

    /// 全部要发的提醒(只要将来的),按时间排好。全天的事以那天的 `allDayTime`
    /// ("HH:MM",设置里的全天提醒时刻)为基准往前推。
    public static func reminders(_ entries: [CountdownEntry], allDayTime: String, now: Date,
                                 calendar: Calendar = .current) -> [CountdownReminder] {
        let (hour, minute) = parseTime(allDayTime)
        func base(_ date: Date, allDay: Bool) -> Date {
            guard allDay else { return date }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                 of: calendar.startOfDay(for: date)) ?? date
        }
        var result: [CountdownReminder] = []
        for entry in entries {
            let startBase = base(entry.start, allDay: entry.allDay)
            for offset in Set(entry.startReminders) {
                result.append(CountdownReminder(
                    eventID: entry.id, title: entry.title,
                    fireDate: startBase.addingTimeInterval(-Double(offset) * 60),
                    isEnd: false, offsetMinutes: offset))
            }
            if let end = entry.end {
                let endBase = base(end, allDay: entry.allDay)
                for offset in Set(entry.endReminders) {
                    result.append(CountdownReminder(
                        eventID: entry.id, title: entry.title,
                        fireDate: endBase.addingTimeInterval(-Double(offset) * 60),
                        isEnd: true, offsetMinutes: offset))
                }
            }
        }
        return result.filter { $0.fireDate > now }.sorted {
            ($0.fireDate, $0.offsetMinutes) < ($1.fireDate, $1.offsetMinutes)
        }
    }

    static func parseTime(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            return (9, 0)
        }
        return (parts[0], parts[1])
    }
}
