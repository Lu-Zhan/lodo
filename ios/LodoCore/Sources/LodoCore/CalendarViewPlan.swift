import Foundation

/// 「日历」页的纯逻辑:几种视图各自显示哪几天、查询哪段区间、怎么翻页,
/// 以及时间轴上重叠事件怎么分列。和 `CalendarWeek` 同一个分层——**不 import
/// EventKit/SwiftUI**,单测 `CalendarViewPlanTests` 不用模拟器、不用日历授权。
///
/// 周一律按**周一起头**(同 `CalendarWeek.start`,0 = 周一的口径),不跟随系统
/// firstWeekday:任务页的重复规则是这个口径,日历页再换一套只会对不上。
public enum CalendarViewMode: String, CaseIterable, Sendable {
    /// 所有:按天分组的日程列表(系统日历 app 的「列表」)。
    case agenda
    case day
    case threeDay
    case week
    case month
    case year

    /// 右上角切换菜单里的名字。
    public var title: String {
        switch self {
        case .agenda: return "所有"
        case .day: return "当日"
        case .threeDay: return "三日"
        case .week: return "本周"
        case .month: return "本月"
        case .year: return "全年"
        }
    }

    /// 时间轴视图一屏几列(日/三日/周);其余视图不是时间轴,返回 nil。
    public var timelineDayCount: Int? {
        switch self {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        default: return nil
        }
    }
}

public enum CalendarViewPlan {

    /// 把任意一天规整成这个视图的"锚点":日/三日是那天零点,周是那周周一,
    /// 月是那月一号,年是那年一月一号。所有列表是今天(它不翻页)。
    ///
    /// 三日**不**规整到某个三天一组的格子里——系统日历的三日视图就是"从这天起
    /// 往后三天",点「今天」回来时今天在最左边。
    public static func anchor(for date: Date, mode: CalendarViewMode,
                              calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        switch mode {
        case .agenda, .day, .threeDay:
            return day
        case .week:
            return CalendarWeek.start(of: day, calendar: calendar)
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
        case .year:
            return calendar.date(from: calendar.dateComponents([.year], from: day)) ?? day
        }
    }

    /// 往前/往后翻 n 页,返回新的锚点。
    public static func shift(_ anchor: Date, mode: CalendarViewMode, by pages: Int,
                             calendar: Calendar = .current) -> Date {
        let shifted: Date?
        switch mode {
        case .agenda: shifted = anchor
        case .day: shifted = calendar.date(byAdding: .day, value: pages, to: anchor)
        case .threeDay: shifted = calendar.date(byAdding: .day, value: 3 * pages, to: anchor)
        case .week: shifted = calendar.date(byAdding: .day, value: 7 * pages, to: anchor)
        case .month: shifted = calendar.date(byAdding: .month, value: pages, to: anchor)
        case .year: shifted = calendar.date(byAdding: .year, value: pages, to: anchor)
        }
        return Self.anchor(for: shifted ?? anchor, mode: mode, calendar: calendar)
    }

    /// 时间轴视图的几列(都是零点)。非时间轴视图返回空数组。
    public static func timelineDays(anchor: Date, mode: CalendarViewMode,
                                    calendar: Calendar = .current) -> [Date] {
        guard let count = mode.timelineDayCount else { return [] }
        let first = Self.anchor(for: anchor, mode: mode, calendar: calendar)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// 月视图的格子:从这个月一号所在那周的周一,到最后一天所在那周的周日,
    /// 总数恒为 7 的倍数(4-6 行)。头尾补进来的是相邻月份的日子,UI 画灰。
    public static func monthGrid(for anchor: Date, calendar: Calendar = .current) -> [Date] {
        let first = Self.anchor(for: anchor, mode: .month, calendar: calendar)
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: first),
              let last = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return [] }
        let gridStart = CalendarWeek.start(of: first, calendar: calendar)
        let gridEnd = CalendarWeek.start(of: last, calendar: calendar)
        var days: [Date] = []
        var day = gridStart
        while day <= gridEnd || days.count % 7 != 0 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// 全年视图的 12 个月(各月一号)。
    public static func months(ofYear anchor: Date, calendar: Calendar = .current) -> [Date] {
        let first = Self.anchor(for: anchor, mode: .year, calendar: calendar)
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: first) }
    }

    /// 所有列表往前看多少天、往后看多少天。系统日历里没有"全部事件"这种查询,
    /// 必须给区间;往前一个月够翻看最近的事,往后一年覆盖绝大多数排期。
    public static let agendaPastDays = 30
    public static let agendaFutureDays = 365

    /// 这个视图要向日历查询的区间(左闭右开)。月视图按整张格子查(头尾补进来
    /// 的邻月日子也要有圆点),全年视图不画事件、只查这一年(有日程的日子
    /// 数字加粗)。
    public static func queryRange(anchor: Date, mode: CalendarViewMode, now: Date = Date(),
                                  calendar: Calendar = .current) -> Range<Date> {
        func plus(_ days: Int, _ date: Date) -> Date {
            calendar.date(byAdding: .day, value: days, to: date) ?? date
        }
        switch mode {
        case .agenda:
            let today = calendar.startOfDay(for: now)
            return plus(-agendaPastDays, today)..<plus(agendaFutureDays, today)
        case .day, .threeDay, .week:
            let days = timelineDays(anchor: anchor, mode: mode, calendar: calendar)
            guard let first = days.first, let last = days.last else { return anchor..<anchor }
            return first..<plus(1, last)
        case .month:
            let grid = monthGrid(for: anchor, calendar: calendar)
            guard let first = grid.first, let last = grid.last else { return anchor..<anchor }
            return first..<plus(1, last)
        case .year:
            let first = Self.anchor(for: anchor, mode: .year, calendar: calendar)
            let next = calendar.date(byAdding: .year, value: 1, to: first) ?? first
            return first..<next
        }
    }

    /// 某一天的事件,全天事件在前,其余按开始时间。
    public static func events(_ events: [CalendarEvent], on day: Date,
                              calendar: Calendar = .current) -> [CalendarEvent] {
        events.filter { $0.occurs(on: day, calendar: calendar) }
            .sorted {
                let lhs = $0.sortDate(on: day, calendar: calendar)
                let rhs = $1.sortDate(on: day, calendar: calendar)
                return lhs == rhs ? $0.title < $1.title : lhs < rhs
            }
    }

    /// 所有列表:按天分组,只留有事件的日子,日期升序。跨天事件在它经过的每
    /// 一天都出现(同系统日历的列表视图)。
    public static func agendaGroups(_ events: [CalendarEvent], in range: Range<Date>,
                                    calendar: Calendar = .current)
        -> [(day: Date, events: [CalendarEvent])] {
        var days = Set<Date>()
        for event in events {
            var day = calendar.startOfDay(for: max(event.start, range.lowerBound))
            let last = min(event.end, range.upperBound)
            // 零长度事件也算它开始的那一天。
            repeat {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < last
        }
        return days.sorted().compactMap { day in
            let list = Self.events(events, on: day, calendar: calendar)
            return list.isEmpty ? nil : (day, list)
        }
    }
}

/// 时间轴上一条定时事件的位置:当天第几分钟到第几分钟,排在重叠组里的第几列、
/// 这组一共几列。UI 据此算 y 坐标和宽度,自己不做任何重叠判断。
public struct CalendarTimelineSlot: Equatable, Sendable {
    public let event: CalendarEvent
    /// 裁到当天以内的起止分钟(0...1440)。
    public let startMinute: Int
    public let endMinute: Int
    public let column: Int
    public let columnCount: Int
}

public enum CalendarTimelineLayout {

    /// 排版时每条事件至少按这么长算:五分钟的事件画出来只有几个点高,标题都
    /// 塞不下;按最短时长参与重叠判断,紧挨着的两条短事件才不会叠在一起。
    public static let minimumDisplayMinutes = 20

    /// 某一天时间轴上的定时事件排版。全天事件和盖满整天的事件不在这里
    /// (它们进顶部的全天行,见 `CalendarEvent.showsInAllDayRow`)。
    ///
    /// 算法:按开始时间排,把传递性重叠的事件并成一组;组内贪心分列(放进第一
    /// 个已经空出来的列),整组共用组内的列数——同一组里的事件等宽并排,
    /// 和系统日历的做法一致。
    public static func layout(_ events: [CalendarEvent], on day: Date,
                              calendar: Calendar = .current) -> [CalendarTimelineSlot] {
        let dayStart = calendar.startOfDay(for: day)
        let items: [(event: CalendarEvent, start: Int, end: Int)] = events
            .filter { $0.occurs(on: day, calendar: calendar) && !$0.showsInAllDayRow(on: day, calendar: calendar) }
            .map { event in
                let start = max(0, min(1440, Int(event.start.timeIntervalSince(dayStart) / 60)))
                let end = max(start, min(1440, Int(event.end.timeIntervalSince(dayStart) / 60)))
                return (event, start, end)
            }
            .sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }

        var result: [CalendarTimelineSlot] = []
        var group: [(item: (event: CalendarEvent, start: Int, end: Int), column: Int)] = []
        var columnEnds: [Int] = []
        var groupEnd = -1

        func flush() {
            let count = max(1, columnEnds.count)
            for entry in group {
                result.append(CalendarTimelineSlot(
                    event: entry.item.event, startMinute: entry.item.start,
                    endMinute: entry.item.end, column: entry.column, columnCount: count))
            }
            group.removeAll()
            columnEnds.removeAll()
            groupEnd = -1
        }

        for item in items {
            let displayEnd = max(item.end, item.start + minimumDisplayMinutes)
            if !group.isEmpty && item.start >= groupEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = displayEnd
                group.append((item, free))
            } else {
                columnEnds.append(displayEnd)
                group.append((item, columnEnds.count - 1))
            }
            groupEnd = max(groupEnd, displayEnd)
        }
        flush()
        return result
    }
}
