import Foundation

// 总览页几张"把现有数据换个角度看"的模块的纯计算(`OverviewInsightsTests`):
// 今日时间轴与空档、旅行中、定时任务运行状态。同 `OverviewCharts`,只做数。

// MARK: - 今日时间轴

/// 「今日日程」大卡上那条横向时间轴:日程画成区间、任务画成点、此刻一条竖线。
public struct OverviewTimeline: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// 默认画 8:00–22:00;有日程/任务/此刻落在外面就往外扩到整点(不超出这一天)。
    public static func make(day: Date, busy: [DateInterval], points: [Date],
                            calendar: Calendar = .current) -> OverviewTimeline {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.dateInterval(of: .day, for: day)?.end ?? dayStart.addingTimeInterval(86400)
        func at(_ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? dayStart
        }
        var lower = at(8)
        var upper = at(22)
        let moments = busy.flatMap { [$0.start, $0.end] } + points
        for moment in moments {
            lower = min(lower, max(moment, dayStart))
            upper = max(upper, min(moment, dayEnd))
        }
        // 往外取整到整点。
        lower = calendar.dateInterval(of: .hour, for: lower)?.start ?? lower
        if let hour = calendar.dateInterval(of: .hour, for: upper), hour.start != upper {
            upper = min(hour.end, dayEnd)
        }
        return OverviewTimeline(start: lower, end: max(upper, lower.addingTimeInterval(3600)))
    }

    /// 某个时刻在轴上的位置(0...1,超出的夹到两端)。
    public func fraction(_ date: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / length))
    }

    /// 轴上该标的整点(每 `step` 小时一个,含两端所在的整点)。
    public func hourMarks(every step: Int = 4, calendar: Calendar = .current) -> [Date] {
        var marks: [Date] = []
        var cursor = start
        while cursor <= end {
            if calendar.component(.hour, from: cursor) % step == 0 { marks.append(cursor) }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    /// `from`…`to` 之间没有日程的空档(重叠的日程先合并),短于 `minimum` 的不算。
    /// 任务没有时长(iOS 已去掉),所以只看日程。
    public static func freeSlots(busy: [DateInterval], from: Date, to: Date,
                                 minimum: TimeInterval = 30 * 60) -> [DateInterval] {
        guard to > from else { return [] }
        let merged = busy.filter { $0.end > from && $0.start < to }
            .sorted { $0.start < $1.start }
            .reduce(into: [DateInterval]()) { result, interval in
                if let last = result.last, interval.start <= last.end {
                    result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
                } else {
                    result.append(interval)
                }
            }
        var slots: [DateInterval] = []
        var cursor = from
        for interval in merged {
            if interval.start > cursor, interval.start.timeIntervalSince(cursor) >= minimum {
                slots.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if to > cursor, to.timeIntervalSince(cursor) >= minimum {
            slots.append(DateInterval(start: cursor, end: to))
        }
        return slots
    }
}

// MARK: - 旅行中

/// 「旅行中」模块:正在进行的那次旅行第几天、接下来去哪、今晚住哪;没有进行中的
/// 就报最近一次要出发的(只看 `horizonDays` 天内)。
public struct OverviewTripStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 第 `day` 天(从 1 起),共 `of` 天。
        case ongoing(day: Int, of: Int)
        /// 还有几天出发(明天 = 1)。
        case upcoming(daysUntil: Int)
    }

    /// 调用方传进来的第几次旅行。
    public let tripIndex: Int
    public let phase: Phase
    /// 还没开始的第一项(进行中时只看这次旅行里的;住宿已入住的不算)。
    public let next: TravelEntry?
    /// 进行中时今天的安排(不含住宿),按时间排。
    public let today: [TravelEntry]
    /// 进行中时今晚住哪。
    public let tonight: TravelEntry?

    public static func build(trips: [(start: Date, end: Date)], entries: [[TravelEntry]],
                             now: Date, horizonDays: Int = 60,
                             calendar: Calendar = .current) -> OverviewTripStatus? {
        let today = calendar.startOfDay(for: now)
        func dayCount(_ trip: (start: Date, end: Date)) -> Int {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.start),
                                               to: calendar.startOfDay(for: trip.end)).day ?? 0
            return max(1, days + 1)
        }
        func upcomingEntry(_ list: [TravelEntry]) -> TravelEntry? {
            list.filter { ($0.start ?? .distantPast) >= now }
                .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        }
        let ongoing = trips.indices.filter { index in
            let start = calendar.startOfDay(for: trips[index].start)
            let end = calendar.startOfDay(for: trips[index].end)
            return start <= today && today <= end
        }.min { trips[$0].start < trips[$1].start }
        if let index = ongoing {
            let list = index < entries.count ? entries[index] : []
            let day = (calendar.dateComponents([.day], from: calendar.startOfDay(for: trips[index].start),
                                               to: today).day ?? 0) + 1
            let todays = TravelPlan.group(list, into: [today], calendar: calendar).first?.entries ?? []
            return OverviewTripStatus(
                tripIndex: index, phase: .ongoing(day: day, of: dayCount(trips[index])),
                next: upcomingEntry(list),
                today: TravelPlan.sorted(todays.filter { $0.kind != .lodging }),
                tonight: TravelPlan.lodgings(on: today, in: list, calendar: calendar).first)
        }
        let upcoming = trips.indices.filter { calendar.startOfDay(for: trips[$0].start) > today }
            .min { trips[$0].start < trips[$1].start }
        guard let index = upcoming else { return nil }
        let days = OverviewTime.daysUntil(trips[index].start, from: now, calendar: calendar)
        guard days <= horizonDays else { return nil }
        let list = index < entries.count ? entries[index] : []
        return OverviewTripStatus(tripIndex: index, phase: .upcoming(daysUntil: days),
                                  next: upcomingEntry(list), today: [], tonight: nil)
    }
}

// MARK: - 定时任务运行状态

/// 「例行状态」模块:每条定时任务最近 7 天每天跑得怎么样 + 下一次什么时候跑。
/// 运行记录里没有"本该在哪个时间槽跑"的字段,所以**没有记录的日子只能算"没记录"**,
/// 不能判成漏跑。
public struct OverviewRoutineStatus: Equatable, Sendable {
    public enum DayState: Equatable, Sendable {
        case none
        case success
        /// 当天有失败、没有成功的。
        case failed
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let enabled: Bool
        /// 最近 `days` 天,最后一个是今天。
        public let days: [DayState]
        public let nextRun: Date?
    }

    public let rows: [Row]
    /// 最近 `days` 天里失败的次数(不论当天后来有没有成功)。
    public let failures: Int
    /// 所有启用中的任务里最近的下一次。
    public let nextRun: (id: UUID, date: Date)?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.failures == rhs.failures
            && lhs.nextRun?.id == rhs.nextRun?.id && lhs.nextRun?.date == rhs.nextRun?.date
    }

    public static func build(routines: [(id: UUID, name: String, enabled: Bool, nextRun: Date?)],
                             runs: [(routineID: UUID, failed: Bool, date: Date)],
                             now: Date, days: Int = 7,
                             calendar: Calendar = .current) -> OverviewRoutineStatus {
        let today = calendar.startOfDay(for: now)
        let dayList = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let earliest = dayList.first ?? today
        var failures = 0
        var states = [UUID: [Date: DayState]]()
        for run in runs where run.date >= earliest && run.date <= now {
            let day = calendar.startOfDay(for: run.date)
            if run.failed {
                failures += 1
                if states[run.routineID]?[day] != .success { states[run.routineID, default: [:]][day] = .failed }
            } else {
                states[run.routineID, default: [:]][day] = .success
            }
        }
        let rows = routines.map { routine in
            Row(id: routine.id, name: routine.name, enabled: routine.enabled,
                days: dayList.map { states[routine.id]?[$0] ?? .none },
                nextRun: routine.enabled ? routine.nextRun : nil)
        }
        let next = rows.compactMap { row in row.nextRun.map { (id: row.id, date: $0) } }
            .min { $0.date < $1.date }
        return OverviewRoutineStatus(rows: rows, failures: failures, nextRun: next)
    }
}
