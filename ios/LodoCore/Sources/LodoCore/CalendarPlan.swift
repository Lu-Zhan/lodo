import Foundation

/// 任务页顶部那条周视图的纯逻辑,以及系统日历事件的值快照。
///
/// 和 `HealthReport` 同一个分层思路:**这里不 import EventKit**——LodoCore 还要在
/// macOS/watchOS 上编译,而且这样周计算和事件归日能离线单测(`CalendarPlanTests`),
/// 不用模拟器、不用真实日历授权。真正读写系统日历的是 app 层的 `CalendarBridge`。
public enum CalendarWeek {

    /// 这一天所在那一周的周一零点。仓库里周几一律 **0 = 周一**(见 Scheduler 的
    /// `(weekday + 5) % 7`),周视图也按周一起头,不跟随系统的 firstWeekday——
    /// 三端的重复事项都按这个口径,周条再换一套只会对不上。
    public static func start(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)  // 1 = 周日
        let offset = (weekday + 5) % 7                          // 0 = 周一
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// 这一天所在那一周的 7 天(周一 → 周日,都是零点)。
    public static func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let first = start(of: date, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// 往前/往后翻 n 周,返回那一周的周一零点。
    public static func shift(_ weekStart: Date, byWeeks weeks: Int,
                             calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: weeks * 7, to: weekStart) ?? weekStart
    }

    /// 周条抬头那行字:同月是「9月22-28日」,跨月是「9月29日-10月5日」,
    /// 跨年多带一个年份「12月29日-2027年1月4日」。
    public static func label(for weekStart: Date, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let startMonth = calendar.component(.month, from: weekStart)
        let endMonth = calendar.component(.month, from: end)
        let startYear = calendar.component(.year, from: weekStart)
        let endYear = calendar.component(.year, from: end)
        let startDay = calendar.component(.day, from: weekStart)
        let endDay = calendar.component(.day, from: end)
        if startYear != endYear {
            return "\(startMonth)月\(startDay)日-\(endYear)年\(endMonth)月\(endDay)日"
        }
        if startMonth != endMonth {
            return "\(startMonth)月\(startDay)日-\(endMonth)月\(endDay)日"
        }
        return "\(startMonth)月\(startDay)-\(endDay)日"
    }
}

/// 系统日历里的一条事件,只留展示要用的几项。
///
/// **不带可编辑性**:这一版日历是只读展示(写方向是把 lodo 任务镜像成事件,
/// 见 `CalendarBridge`),系统事件在 app 里点不动也改不了,所以不需要把
/// EKEvent 整个搬过来。
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// 事件所属日历的名字(「工作」「家庭」这类),行尾灰字展示,用来区分来源。
    public let calendarTitle: String

    public init(id: String, title: String, start: Date, end: Date,
                isAllDay: Bool, calendarTitle: String) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
    }

    /// 这条事件是否落在某一天里。**按区间相交判断**,不是"开始时间是不是那天"——
    /// 跨天的会议和多天的全天事件(旅行、请假)在中间那几天也该看得见。
    /// 结束时间正好卡在第二天零点的(典型的"全天事件 endDate 是次日零点")
    /// 不算进第二天,否则每个全天事件都会多出一天。
    public func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start < dayEnd && end > dayStart
    }

    /// 排序键:全天事件排在当天最前面(它没有具体时间,夹在两条定时事项中间
    /// 反而读不出先后)。
    public func sortDate(on day: Date, calendar: Calendar = .current) -> Date {
        isAllDay ? calendar.startOfDay(for: day) : start
    }
}

/// 一条 lodo 任务要镜像成系统日历事件时的取值。纯值类型,方便 app 层从
/// SwiftData 的 `TaskItem` 摘出来交给 `CalendarBridge`,也方便单测这段取值规则。
public struct CalendarTaskMirror: Equatable, Sendable {
    public let uuid: UUID
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// 重复事项。**双向同步里它只推不拉**:镜像的是"下一次发生",在日历里把这一次
    /// 挪个时间没法表达"整条重复规则怎么变",硬回写会把规则改坏,所以下一次对账
    /// 会把它推回原样(删除仍然照常生效,见 `CalendarSyncPlanner`)。
    public let isRecurring: Bool

    public init(uuid: UUID, title: String, start: Date, end: Date, isAllDay: Bool,
                isRecurring: Bool = false) {
        self.uuid = uuid
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
    }

    /// 时长(分钟),回写任务时用。
    public var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// 没填时长的事项在日历上占多久。日历事件必须有长度,零长度的在月/周视图里
    /// 基本看不见;半小时是个"能看见又不至于糊掉一上午"的折中。
    public static let defaultDurationMinutes = 30

    /// 从一条任务的值快照取镜像。**只镜像未完成的事项**(完成了就该从日历上消失),
    /// 重复事项只镜像**下一次**发生——把每一次都写进去是无上界的,而 app 自己
    /// 也只显示下一次(同 `TaskItem` 的单条虚拟行)。
    /// (`TaskData` 本身不带 uuid——它是纯数据快照,uuid 长在各端的持久化模型上,
    /// 所以调用方把 uuid 一起传进来。)
    public static func from(_ task: TaskData, uuid: UUID) -> CalendarTaskMirror? {
        guard task.status == .pending, !task.title.isEmpty else { return nil }
        let start = task.isRecurring ? task.nextRemindAt : task.remindAt
        let minutes = task.durationMinutes > 0 ? task.durationMinutes : defaultDurationMinutes
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return CalendarTaskMirror(uuid: uuid, title: task.title, start: start, end: end,
                                  isAllDay: task.allDay, isRecurring: task.isRecurring)
    }

    /// 写进事件的 URL,同时也是回读时认领"这条事件是哪件任务"的凭据。
    /// EKEvent 没有自定义字段,notes 又是用户可见可改的,URL 是现成且稳定的一格。
    public var eventURL: URL? { URL(string: "lodo://task/\(uuid.uuidString)") }

    /// 反向解析:从事件 URL 认出任务 uuid,认不出的说明不是 lodo 写的。
    public static func taskUUID(fromEventURL url: URL?) -> UUID? {
        guard let url, url.scheme == "lodo", url.host == "task" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
