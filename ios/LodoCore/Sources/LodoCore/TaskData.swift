import Foundation

/// 事项状态。
public enum TaskStatus: String, Codable, Sendable {
    case pending
    case done
}

/// 时长事项的阶段:等待开始提醒 / 已开始等待结束提醒。
public enum TaskPhase: String, Codable, Sendable {
    case start
    case end
}

/// 重复类型。
public enum RepeatType: String, Codable, CaseIterable, Sendable {
    case none
    case daily
    case weekly
}

public let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

/// 平台无关的事项数据,语义与 web 版 lodo/models.py 的 Task 一一对应。
public struct TaskData: Equatable, Sendable {
    public var title: String
    public var remindAt: Date
    public var durationMinutes: Int
    public var allDay: Bool
    public var repeatType: RepeatType
    /// 每周重复选中的周几,0=周一 … 6=周日。
    public var repeatDays: [Int]
    /// 重复事项每天的提醒时间点,"HH:MM"。
    public var repeatTimes: [String]
    public var status: TaskStatus
    public var phase: TaskPhase
    public var nextRemindAt: Date
    public var doneAt: Date?

    public init(
        title: String,
        remindAt: Date,
        durationMinutes: Int = 0,
        allDay: Bool = false,
        repeatType: RepeatType = .none,
        repeatDays: [Int] = [],
        repeatTimes: [String] = [],
        status: TaskStatus = .pending,
        phase: TaskPhase = .start,
        nextRemindAt: Date? = nil,
        doneAt: Date? = nil
    ) {
        self.title = title
        self.remindAt = remindAt
        self.durationMinutes = durationMinutes
        self.allDay = allDay
        self.repeatType = repeatType
        self.repeatDays = repeatDays
        self.repeatTimes = repeatTimes
        self.status = status
        self.phase = phase
        self.nextRemindAt = nextRemindAt ?? remindAt
        self.doneAt = doneAt
    }

    public var isRecurring: Bool { repeatType != .none }

    /// 重复规则的可读描述,如"每周一、三 09:00/21:00"。
    public var repeatLabel: String {
        guard isRecurring else { return "" }
        let times = repeatTimes.joined(separator: "/")
        if repeatType == .daily { return "每天 \(times)" }
        let days = repeatDays.sorted()
            .map { String(weekdayNames[$0].dropFirst()) }
            .joined(separator: "、")
        return "每周\(days) \(times)"
    }

    public func isDue(now: Date) -> Bool {
        status == .pending && now >= nextRemindAt
    }
}
