import Foundation
import SwiftData

/// 一条用户自定义的**定时任务**:到设定的时间点自动让 AI 跑一次自己写的指令,
/// 把结果推给用户(如"总结今日待办""看天气给穿搭建议""今日市场动态")。
///
/// 与"每日待办汇总"(`AppSettings.digest*`)的区别:汇总是内置的、只讲待办、
/// 正文由 `summarizeToday` 固定生成;定时任务的指令完全由用户写,可以联网、
/// 可以带上待办上下文,数量不限。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求,
/// 与 TaskItem/MemoryItem/AgentThread 一致)。时间点/周几沿用待办那套持久化格式:
/// 时间点是 "HH:MM" 列表(这里存成逗号分隔的字符串,和 `AppSettings.digestTimes`
/// 的存法一致),周几 0=周一 … 6=周日,repeat_type 复用 `RepeatType` 的
/// daily/weekly 字符串。
@Model
public final class AIRoutine {
    public var uuid: UUID = UUID()
    /// 任务名,同时是通知标题(如"今日穿搭")。
    public var name: String = ""
    /// 用户写的指令,原样发给 AI(如"看看今天上海的天气,给一句穿衣建议")。
    public var prompt: String = ""
    public var enabled: Bool = true
    /// "HH:MM" 时间点列表,逗号分隔;一天可以有多个。
    public var timesRaw: String = "08:00"
    /// "daily" 或 "weekly"(复用 `RepeatType` 的持久化字符串)。
    public var repeatTypeRaw: String = RepeatType.daily.rawValue
    /// weekly 时选中的周几,逗号分隔,0=周一 … 6=周日。
    public var daysRaw: String = "0,1,2,3,4,5,6"
    /// 把今天的待办列表一起给 AI 当上下文(总结类任务要开,天气/行情类不需要)。
    public var includeTasks: Bool = false
    /// 允许 AI 联网搜索(实际是否可用还要看有没有配 Tavily key)。
    public var useWebSearch: Bool = false
    /// 结果发系统通知;关掉就只在 app 里看。
    public var notify: Bool = true
    public var createdAt: Date = Date.now
    /// 最近一次**按计划**跑完的那个时间槽(不是运行时刻)。补跑判定只看它,
    /// 手动"立即运行"不写——手动跑过不该顶掉当天计划内的那次。
    public var lastScheduledSlot: Date?

    public init(name: String = "", prompt: String = "", times: [String] = ["08:00"],
                repeatType: RepeatType = .daily, days: [Int] = Array(0...6),
                includeTasks: Bool = false, useWebSearch: Bool = false,
                notify: Bool = true, enabled: Bool = true) {
        self.uuid = UUID()
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.timesRaw = times.joined(separator: ",")
        self.repeatTypeRaw = repeatType.rawValue
        self.daysRaw = days.sorted().map(String.init).joined(separator: ",")
        self.includeTasks = includeTasks
        self.useWebSearch = useWebSearch
        self.notify = notify
        self.createdAt = Date()
    }

    public var times: [String] {
        get { timesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
        set { timesRaw = newValue.joined(separator: ",") }
    }

    public var repeatType: RepeatType {
        get { RepeatType(rawValue: repeatTypeRaw) ?? .daily }
        set { repeatTypeRaw = newValue.rawValue }
    }

    public var days: [Int] {
        get {
            daysRaw.split(separator: ",").compactMap { Int($0) }
                .filter { (0...6).contains($0) }.sorted()
        }
        set { daysRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    /// 下一次计划触发时间;没有可用时间点(或 weekly 一天都没选)时为 nil。
    public func nextRun(after: Date = Date()) -> Date? {
        RoutineSchedule.next(after: after, times: times, repeatType: repeatType, days: days)
    }

    /// 列表行的说明文字,如"每天 08:00" / "每周一、三 07:30/21:00"。
    public var caption: String {
        let timeText = times.sorted().joined(separator: "/")
        guard !timeText.isEmpty else { return "未设置时间" }
        if repeatType == .weekly {
            let dayText = days.map { String(weekdayNames[$0].dropFirst()) }.joined(separator: "、")
            return dayText.isEmpty ? "未选择星期" : "每周\(dayText) \(timeText)"
        }
        return "每天 \(timeText)"
    }
}

extension AIRoutine {
    /// 新建时可一键套用的模板(名称、指令、时间、要不要待办上下文/联网)。
    /// 只是预填表单,用户随便改;"自定义"就是空白表单,不在这里列。
    public struct Preset: Identifiable, Sendable {
        public let name: String
        public let prompt: String
        public let time: String
        public let includeTasks: Bool
        public let useWebSearch: Bool
        public let symbol: String

        public var id: String { name }
    }

    public static let presets: [Preset] = [
        Preset(name: "今日待办总结",
               prompt: "总结我今天要做的事,指出哪几件优先处理、哪些可以往后放,末尾给一句今天的行动重点。",
               time: "08:00", includeTasks: true, useWebSearch: false,
               symbol: "checklist"),
        Preset(name: "今日天气穿搭",
               prompt: "查一下我所在城市今天的天气,告诉我温度区间、要不要带伞,再给一句具体的穿衣建议。",
               time: "07:30", includeTasks: false, useWebSearch: true,
               symbol: "cloud.sun"),
        Preset(name: "今日投资参考",
               prompt: "汇总今天值得关注的市场动态(A 股与美股主要指数、重要消息),客观陈述,末尾加一句风险提示。",
               time: "08:30", includeTasks: false, useWebSearch: true,
               symbol: "chart.line.uptrend.xyaxis"),
        Preset(name: "睡前复盘",
               prompt: "回顾我今天完成和没完成的事,用一句话点评,并给明天一个具体的小改进建议。",
               time: "21:30", includeTasks: true, useWebSearch: false,
               symbol: "moon.stars"),
    ]

    public convenience init(preset: Preset) {
        self.init(name: preset.name, prompt: preset.prompt, times: [preset.time],
                  repeatType: .daily, days: Array(0...6),
                  includeTasks: preset.includeTasks, useWebSearch: preset.useWebSearch)
    }
}

/// 定时任务的一次运行结果(成功或失败都留一条,用户能看到"为什么没出来")。
/// 单独一张表而不是往 `AIRoutine` 上挂最后一次结果,是为了"总览"能按天聚合
/// 展示今天所有例行任务的产出,也方便回看前几天的。
@Model
public final class AIRoutineRun {
    public var uuid: UUID = UUID()
    /// 关联的定时任务;任务被删掉后历史记录也会跟着删(调用方负责),
    /// 不用 SwiftData 关系是为了和库里其他模型一样保持展平字段、CloudKit 友好。
    public var routineUUID: UUID = UUID()
    /// 运行当时的任务名(任务改名/删除后历史记录仍能自解释)。
    public var routineName: String = ""
    public var text: String = ""
    public var failed: Bool = false
    /// 用户手动点"立即运行"产生的,不是计划内触发的。
    public var manual: Bool = false
    public var createdAt: Date = Date.now

    public init(routineUUID: UUID, routineName: String, text: String,
                failed: Bool = false, manual: Bool = false) {
        self.uuid = UUID()
        self.routineUUID = routineUUID
        self.routineName = routineName
        self.text = text
        self.failed = failed
        self.manual = manual
        self.createdAt = Date()
    }
}

/// 定时任务的触发时间计算(纯函数,可脱离 SwiftData 单测)。
/// 周几约定与时间点格式和 `Scheduler.nextOccurrence` 完全一致,8 天前瞻/回看。
public enum RoutineSchedule {
    /// 错过的槽位还值不值得补跑的时间窗:6 小时。
    /// 早上 8 点的"今日待办总结"晚上 10 点才补出来毫无意义,过期就跳过等下一次。
    public static let catchUpWindow: TimeInterval = 6 * 3600

    /// `after` 之后的下一次触发时间。
    public static func next(after: Date, times: [String], repeatType: RepeatType,
                            days: [Int], calendar: Calendar = .current) -> Date? {
        let slots = normalizedTimes(times)
        guard !slots.isEmpty, let dayFilter = dayFilter(repeatType, days) else { return nil }
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: after)),
                  dayFilter.contains(weekday(of: day, calendar)) else { continue }
            for candidate in slots.compactMap({ date(slot: $0, on: day, calendar) })
            where candidate > after {
                return candidate
            }
        }
        return nil
    }

    /// `atOrBefore` 之前(含当刻)最近的一次触发时间。
    public static func latestSlot(atOrBefore moment: Date, times: [String],
                                  repeatType: RepeatType, days: [Int],
                                  calendar: Calendar = .current) -> Date? {
        let slots = normalizedTimes(times)
        guard !slots.isEmpty, let dayFilter = dayFilter(repeatType, days) else { return nil }
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -offset,
                                          to: calendar.startOfDay(for: moment)),
                  dayFilter.contains(weekday(of: day, calendar)) else { continue }
            let candidates = slots.compactMap { date(slot: $0, on: day, calendar) }
                .filter { $0 <= moment }
            if let last = candidates.last { return last }
        }
        return nil
    }

    /// 现在该不该跑,该跑的话是哪个槽位。
    /// 条件:最近一个已过槽位还在补跑窗口内,且这个槽位没跑过。
    /// app 在后台醒来、回到前台、用户改完设置时都用同一个判断,不会重复跑同一槽位。
    public static func dueSlot(now: Date, lastSlot: Date?, times: [String],
                               repeatType: RepeatType, days: [Int],
                               window: TimeInterval = catchUpWindow,
                               calendar: Calendar = .current) -> Date? {
        guard let slot = latestSlot(atOrBefore: now, times: times, repeatType: repeatType,
                                    days: days, calendar: calendar),
              now.timeIntervalSince(slot) <= window else { return nil }
        if let lastSlot, lastSlot >= slot { return nil }
        return slot
    }

    // MARK: - 内部

    /// 去掉格式不对的时间点并按时间排序("9:5" 这种不合法值直接丢掉)。
    private static func normalizedTimes(_ times: [String]) -> [(hour: Int, minute: Int)] {
        times.compactMap { hhmm -> (hour: Int, minute: Int)? in
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]),
                  (0...59).contains(parts[1]) else { return nil }
            return (parts[0], parts[1])
        }
        .sorted { $0.hour == $1.hour ? $0.minute < $1.minute : $0.hour < $1.hour }
    }

    /// daily 是每天;weekly 一天都没选时返回 nil(永不触发)。
    private static func dayFilter(_ repeatType: RepeatType, _ days: [Int]) -> Set<Int>? {
        guard repeatType == .weekly else { return Set(0..<7) }
        let selected = Set(days.filter { (0...6).contains($0) })
        return selected.isEmpty ? nil : selected
    }

    /// Calendar.weekday: 1=周日…7=周六 → 项目约定的 0=周一…6=周日。
    private static func weekday(of day: Date, _ calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: day) + 5) % 7
    }

    private static func date(slot: (hour: Int, minute: Int), on day: Date,
                            _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day)
    }
}
