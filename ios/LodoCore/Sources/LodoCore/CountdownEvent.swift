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
    /// 归档:页面主列表、小组件、总览、提醒里都不再出现,收在「已归档」里可以恢复。
    public var archived: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), title: String = "", startDate: Date = .now,
                endDate: Date? = nil, allDay: Bool = true, notes: String = "",
                startReminders: [Int] = [], endReminders: [Int] = [],
                showInWidget: Bool = false, archived: Bool = false, createdAt: Date = .now) {
        self.uuid = uuid
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.allDay = allDay
        self.notes = notes
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
        self.archived = archived
        self.createdAt = createdAt
    }

    /// 值快照,交给纯逻辑计算。
    public var entry: CountdownEntry {
        CountdownEntry(id: uuid, title: title, start: startDate, end: endDate, allDay: allDay,
                       startReminders: startReminders, endReminders: endReminders,
                       showInWidget: showInWidget, archived: archived)
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
    public let archived: Bool

    public init(id: UUID = UUID(), title: String, start: Date, end: Date? = nil,
                allDay: Bool = true, startReminders: [Int] = [], endReminders: [Int] = [],
                showInWidget: Bool = false, archived: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
        self.archived = archived
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

    /// 小组件上显示哪几件:勾了"显示在小组件"、没归档的,按页面同样的顺序取前 3 件。
    public static func widgetEntries(_ entries: [CountdownEntry], now: Date,
                                     calendar: Calendar = .current) -> [CountdownEntry] {
        Array(sorted(entries.filter { $0.showInWidget && !$0.archived }, now: now,
                     calendar: calendar).prefix(widgetLimit))
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
        // 归档了的不再提醒。
        for entry in entries where !entry.archived {
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

    // MARK: - 正数日(总览小组件)

    /// 总览「正数日」小组件上的一件:往上数的那件事,和它接下来的节点(没有就是 nil)。
    public struct CountUp: Equatable, Sendable, Identifiable {
        public let entry: CountdownEntry
        public let next: Milestone?
        public var id: UUID { entry.id }
    }

    /// 正数日 = 页面「正数日」那一组(已经过去、没归档的)。**快到周年/整百天的排前面**
    /// ——小组件只放得下几件,"3 天后满两周年"比一件三年前结束的旅行值得占位;
    /// 没有节点的(有结束日的事不算周年)按页面顺序排在后面。
    /// 节点只看一年之内,一年里总有下一个周年。
    public static func countUps(_ entries: [CountdownEntry], now: Date,
                                calendar: Calendar = .current) -> [CountUp] {
        let past = sorted(entries.filter { !$0.archived && isPast($0, now: now, calendar: calendar) },
                          now: now, calendar: calendar)
        let items = past.map { entry in
            // 有结束日的(一次旅行、一段项目)"满几周年"没意义,只给单日的纪念日算节点。
            CountUp(entry: entry,
                    next: entry.end == nil
                        ? milestones(entry, now: now, horizonDays: 366, calendar: calendar).first
                        : nil)
        }
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        return items.sorted { a, b in
            switch (a.next?.daysAway, b.next?.daysAway) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return order[a.id]! < order[b.id]!
            }
        }
    }

    // MARK: - 接下来的节点(AI 建议的素材)

    /// 一件事接下来值得一提的节点。
    public struct Milestone: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// 还没开始的事:离开始还有几天。
            case start
            /// 过去的日子满 N 周年(N ≥ 1)。
            case anniversary(years: Int)
            /// 过去的日子满 N 天(整百,N ≥ 100)。
            case dayCount(Int)
        }
        public let kind: Kind
        public let date: Date
        /// 离那天还有几天(0 = 就是今天)。
        public let daysAway: Int

        public init(kind: Kind, date: Date, daysAway: Int) {
            self.kind = kind
            self.date = date
            self.daysAway = daysAway
        }
    }

    /// 一件事接下来的节点,近的在前。还没开始的只有"开始";开始了的(纪念日、
    /// 在一起、入职这类正数日)给下一个周年和下一个整百天——"马上两周年啦"
    /// "明天就满 1000 天"。只看 `horizonDays` 天以内的。
    public static func milestones(_ entry: CountdownEntry, now: Date, horizonDays: Int = 60,
                                  calendar: Calendar = .current) -> [Milestone] {
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: entry.start)
        func days(to date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        }
        var result: [Milestone] = []
        if startDay > today {
            result.append(Milestone(kind: .start, date: startDay, daysAway: days(to: startDay)))
        } else {
            // 下一个周年:今天正好是周年就算今天。2/29 在非闰年落 2/28(Calendar 自己处理)。
            let passed = calendar.dateComponents([.year], from: startDay, to: today).year ?? 0
            for years in [passed, passed + 1] where years >= 1 {
                if let date = calendar.date(byAdding: .year, value: years, to: startDay),
                   calendar.startOfDay(for: date) >= today {
                    result.append(Milestone(kind: .anniversary(years: years), date: date,
                                            daysAway: days(to: date)))
                    break
                }
            }
            // 下一个整百天:按"已经 N 天"那个口径(开始那天算第 0 天)。
            let elapsed = calendar.dateComponents([.day], from: startDay, to: today).day ?? 0
            let next = max(100, elapsed % 100 == 0 ? elapsed : (elapsed / 100 + 1) * 100)
            if let date = calendar.date(byAdding: .day, value: next, to: startDay) {
                result.append(Milestone(kind: .dayCount(next), date: date, daysAway: next - elapsed))
            }
        }
        return result.filter { $0.daysAway <= horizonDays }.sorted { $0.daysAway < $1.daysAway }
    }

    /// 给 AI 写"今日一句"的素材:每件没归档的事一行,带已经/还有几天和接下来的节点。
    /// 固定中文(喂给模型的,不跟应用内语言走)。没有值得说的节点时也照样列出。
    public static func promptSummary(_ entries: [CountdownEntry], now: Date,
                                     calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = sorted(entries.filter { !$0.archived }, now: now, calendar: calendar)
            .map { entry -> String in
                let span = primary(entry, now: now, calendar: calendar)
                var line = "「\(entry.title)」\(formatter.string(from: entry.start))"
                if let end = entry.end { line += " 至 \(formatter.string(from: end))" }
                switch span.milestone {
                case .untilStart: line += ",还有 \(span.days) 天开始"
                case .untilEnd: line += ",进行中,还有 \(span.days) 天结束"
                case .sinceStart: line += ",已经 \(span.days) 天"
                case .sinceEnd: line += ",已结束 \(span.days) 天"
                }
                let upcoming = milestones(entry, now: now, calendar: calendar).compactMap { m -> String? in
                    let when = m.daysAway == 0 ? "今天" : "\(m.daysAway) 天后"
                    switch m.kind {
                    case .start: return nil
                    case .anniversary(let years): return "\(when)满 \(years) 周年"
                    case .dayCount(let n): return "\(when)满 \(n) 天"
                    }
                }
                if !upcoming.isEmpty { line += ";" + upcoming.joined(separator: "、") }
                return line
            }
        return lines.joined(separator: "\n")
    }

    static func parseTime(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            return (9, 0)
        }
        return (parts[0], parts[1])
    }
}
