import Foundation

/// 总览页的 widget 模块:有哪几种、各自能用什么尺寸、用户排好的布局怎么存、
/// 两列网格怎么排。纯逻辑,不 import SwiftUI,单测 `OverviewLayoutTests`。
///
/// **rawValue 是持久化字符串,别改**——布局 JSON 里存的就是它;新增种类只往后加,
/// 老布局里没有的种类解码时自动补在末尾(见 `OverviewLayout.decode`)。
public enum OverviewWidgetKind: String, CaseIterable, Codable, Sendable {
    /// 此刻:时间、日期星期、今天过去了多少、第几周。
    case clock
    /// 接下来:最近的一件任务或日程,带倒计时。
    case nextUp
    /// 已到期提醒(纠缠中的那些)。
    case due
    /// 今天任务:还剩哪些 + 今天完成了几件。
    case today
    /// 今日日程:系统日历里今天的事件(连了日历才有)。
    case agenda
    /// 倒数日:即将开始的旅行、人脉生日。
    case countdown
    /// 今日例行:定时任务今天跑出来的结果。
    case routines
    /// 处理建议(AI)。
    case suggestion
    /// 今天的记忆(AI 总结)。
    case memories
    /// 健康(AI 一句话,健康开关开着才有内容)。
    case health

    public var title: String {
        switch self {
        case .clock: return "此刻"
        case .nextUp: return "接下来"
        case .due: return "已到期提醒"
        case .today: return "今天任务"
        case .agenda: return "今日日程"
        case .countdown: return "倒数日"
        case .routines: return "今日例行"
        case .suggestion: return "处理建议"
        case .memories: return "今天的记忆"
        case .health: return "健康"
        }
    }

    public var systemImage: String {
        switch self {
        case .clock: return "clock"
        case .nextUp: return "arrow.forward.circle"
        case .due: return "bell.badge"
        case .today: return "checklist"
        case .agenda: return "calendar"
        case .countdown: return "hourglass"
        case .routines: return "clock.badge"
        case .suggestion: return "sparkles"
        case .memories: return "sparkles.rectangle.stack"
        case .health: return "heart.text.square"
        }
    }

    /// 能选的尺寸。列表型/AI 长文本的只给大卡——半宽里塞一段话或三行任务
    /// 只剩省略号;时钟只给小卡,整宽一个时钟太空。
    public var allowedSizes: [OverviewWidgetSize] {
        switch self {
        case .clock: return [.small]
        case .nextUp, .today, .agenda, .countdown: return [.small, .large]
        case .due, .routines, .suggestion, .memories, .health: return [.large]
        }
    }

    public var defaultSize: OverviewWidgetSize {
        switch self {
        case .clock, .nextUp, .countdown: return .small
        default: return .large
        }
    }
}

public enum OverviewWidgetSize: String, Codable, Sendable {
    /// 半宽,两张并排一行。
    case small
    /// 整宽。
    case large
}

public struct OverviewWidgetItem: Codable, Equatable, Sendable, Identifiable {
    public var kind: OverviewWidgetKind
    public var size: OverviewWidgetSize
    public var isVisible: Bool

    public var id: OverviewWidgetKind { kind }

    public init(kind: OverviewWidgetKind, size: OverviewWidgetSize? = nil, isVisible: Bool = true) {
        self.kind = kind
        let wanted = size ?? kind.defaultSize
        self.size = kind.allowedSizes.contains(wanted) ? wanted : kind.defaultSize
        self.isVisible = isVisible
    }
}

public struct OverviewLayout: Equatable, Sendable {
    public var items: [OverviewWidgetItem]

    public init(items: [OverviewWidgetItem]) {
        self.items = items
    }

    /// 默认布局:时间相关的放最上面(今天/接下来 → 到期 → 今天任务 → 日程),
    /// AI 生成的几段放在后面——它们要等网络,放前面会让首屏跳动。
    public static let `default` = OverviewLayout(items: [
        .init(kind: .clock), .init(kind: .nextUp),
        .init(kind: .due), .init(kind: .today), .init(kind: .agenda),
        .init(kind: .countdown), .init(kind: .routines, size: .large),
        .init(kind: .suggestion), .init(kind: .memories), .init(kind: .health),
    ])

    /// 从存储的 JSON 恢复。容错:解不开 → 默认布局;重复的种类只留第一个;
    /// 认不出的种类(新版本存的、又装回老版本)丢掉;老布局里没有的新种类按
    /// 默认尺寸、**显示**补在末尾——新功能不该因为用户动过布局就永远看不见。
    /// 尺寸不在允许范围内的(某种类后来收窄了尺寸)改回默认尺寸。
    public static func decode(_ string: String?) -> OverviewLayout {
        guard let data = string?.data(using: .utf8), !data.isEmpty,
              let raw = try? JSONDecoder().decode([RawItem].self, from: data) else {
            return .default
        }
        var seen = Set<OverviewWidgetKind>()
        var items: [OverviewWidgetItem] = []
        for entry in raw {
            guard let kind = OverviewWidgetKind(rawValue: entry.kind), !seen.contains(kind) else { continue }
            seen.insert(kind)
            items.append(OverviewWidgetItem(
                kind: kind, size: entry.size.flatMap(OverviewWidgetSize.init(rawValue:)),
                isVisible: entry.isVisible ?? true))
        }
        for kind in OverviewWidgetKind.allCases where !seen.contains(kind) {
            items.append(OverviewWidgetItem(kind: kind))
        }
        return OverviewLayout(items: items)
    }

    public func encoded() -> String {
        let raw = items.map { RawItem(kind: $0.kind.rawValue, size: $0.size.rawValue, isVisible: $0.isVisible) }
        guard let data = try? JSONEncoder().encode(raw) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 存储格式里全是字符串:认不出的值要能跳过,而不是让整份布局解码失败。
    private struct RawItem: Codable {
        var kind: String
        var size: String?
        var isVisible: Bool?
    }

    /// 两列网格的行:大卡独占一行,相邻的两张小卡并排;小卡后面紧跟大卡
    /// (或者它是最后一张)时独占半行、右边留空——**不为了凑满而调换顺序**,
    /// 用户排的先后就是看的先后。只排显示中的。
    public func rows() -> [[OverviewWidgetItem]] {
        var rows: [[OverviewWidgetItem]] = []
        var pendingSmall: OverviewWidgetItem?
        for item in items where item.isVisible {
            switch item.size {
            case .large:
                if let small = pendingSmall {
                    rows.append([small])
                    pendingSmall = nil
                }
                rows.append([item])
            case .small:
                if let small = pendingSmall {
                    rows.append([small, item])
                    pendingSmall = nil
                } else {
                    pendingSmall = item
                }
            }
        }
        if let small = pendingSmall { rows.append([small]) }
        return rows
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // 等价于 Array.move(fromOffsets:toOffset:)(那个在 SwiftUI 里),这里自己写一遍
        // 免得 LodoCore 依赖 SwiftUI。
        let moving = source.sorted().map { items[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { items.remove(at: index) }
        items.insert(contentsOf: moving, at: min(destination - before, items.count))
    }
}

// MARK: - 时间相关的小计算

public enum OverviewTime {

    /// 今天过去了多少(0...1)。
    public static func dayProgress(at now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        return min(1, max(0, now.timeIntervalSince(start) / 86400))
    }

    /// 从今天零点数到 `date` 那天零点隔了几天:今天 0、明天 1,过去的为负。
    public static func daysUntil(_ date: Date, from now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 生日的下一次(今天就是生日时返回今天)。2 月 29 日出生、今年不是闰年时
    /// 落在 2 月 28 日——系统日历也是这么处理的。
    public static func nextBirthday(_ birthday: Date, after now: Date,
                                    calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        let parts = calendar.dateComponents([.month, .day], from: birthday)
        guard let month = parts.month, let day = parts.day else { return nil }
        let year = calendar.component(.year, from: today)
        for candidateYear in [year, year + 1] {
            var components = DateComponents(year: candidateYear, month: month, day: day)
            if calendar.date(from: components).map({ calendar.component(.month, from: $0) }) != month {
                components.day = day - 1  // 2/29 → 2/28
            }
            if let date = calendar.date(from: components), date >= today { return date }
        }
        return nil
    }

    /// "还有多久"的一句话:几分钟后 / 几小时后 / 明天 / N 天后;已经过了的是"已开始"。
    public static func relativeLabel(to date: Date, from now: Date, calendar: Calendar = .current) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "已开始" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) 分钟后" }
        let days = daysUntil(date, from: now, calendar: calendar)
        if days == 0 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时后" : "\(hours) 小时 \(rest) 分钟后"
        }
        if days == 1 { return "明天" }
        return "\(days) 天后"
    }
}

/// 倒数日里的一条。
public struct OverviewCountdownEntry: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case trip, birthday
    }
    public let id: String
    public let title: String
    public let date: Date
    public let kind: Kind

    public init(id: String, title: String, date: Date, kind: Kind) {
        self.id = id
        self.title = title
        self.date = date
        self.kind = kind
    }

    /// 汇总倒数日:还没结束的旅行(进行中的也算,按出发日排,出发日可能已过)、
    /// 生日取下一次。只看未来 `horizonDays` 天以内——一年后的生日摆在这里
    /// 不是"重要的时间信息"。按日期升序。
    public static func build(trips: [(id: String, title: String, start: Date, end: Date)],
                             birthdays: [(id: String, name: String, birthday: Date)],
                             now: Date, horizonDays: Int = 60,
                             calendar: Calendar = .current) -> [OverviewCountdownEntry] {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays + 1, to: today) else { return [] }
        var entries: [OverviewCountdownEntry] = []
        for trip in trips where calendar.startOfDay(for: trip.end) >= today && trip.start < horizon {
            entries.append(.init(id: "trip-\(trip.id)", title: trip.title, date: trip.start, kind: .trip))
        }
        for person in birthdays {
            guard let next = OverviewTime.nextBirthday(person.birthday, after: now, calendar: calendar),
                  next < horizon else { continue }
            entries.append(.init(id: "birthday-\(person.id)", title: person.name, date: next, kind: .birthday))
        }
        return entries.sorted { $0.date == $1.date ? $0.title < $1.title : $0.date < $1.date }
    }
}
