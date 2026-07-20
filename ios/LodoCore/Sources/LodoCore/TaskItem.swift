import Foundation
import SwiftData

/// SwiftData 持久化模型,字段与 web 版 tasks 表对齐;调度计算通过 TaskData 互转交给 Scheduler。
/// 放在 LodoCore(而不是主 App target)里,是为了让 iOS/macOS 主 App 和 Watch App
/// 共用同一份模型定义,不需要手动维护两份保持字段一致。
/// 每个存储属性都在声明处给了默认值(不是只在 init 里赋值)、且 uuid 去掉了
/// `.unique` 约束——这两点是 CloudKit 同步的硬性要求(CloudKit 不支持唯一约束,
/// schema 里每个字段都要有默认值),uuid 的唯一性改由应用层保证(每次 UUID() 生成)。
@Model
public final class TaskItem {
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var remindAt: Date = Date.now
    public var durationMinutes: Int = 0
    public var allDay: Bool = false
    public var repeatTypeRaw: String = "none"
    public var repeatDays: [Int] = []
    public var repeatTimes: [String] = []
    public var statusRaw: String = "pending"
    public var phaseRaw: String = "start"
    public var nextRemindAt: Date = Date.now
    public var createdAt: Date = Date.now
    public var doneAt: Date?
    /// 导出到系统提醒事项后的 EKReminder identifier(或导入来源),用于去重与更新。
    public var ekIdentifier: String?

    public init(
        title: String,
        remindAt: Date,
        durationMinutes: Int = 0,
        allDay: Bool = false,
        repeatType: RepeatType = .none,
        repeatDays: [Int] = [],
        repeatTimes: [String] = [],
        status: TaskStatus = .pending,
        nextRemindAt: Date? = nil,
        doneAt: Date? = nil,
        ekIdentifier: String? = nil
    ) {
        self.uuid = UUID()
        self.title = title
        self.remindAt = remindAt
        self.durationMinutes = durationMinutes
        self.allDay = allDay
        self.repeatTypeRaw = repeatType.rawValue
        self.repeatDays = repeatDays
        self.repeatTimes = repeatTimes
        self.statusRaw = status.rawValue
        self.phaseRaw = TaskPhase.start.rawValue
        self.nextRemindAt = nextRemindAt ?? remindAt
        self.createdAt = Date()
        self.doneAt = doneAt
        self.ekIdentifier = ekIdentifier
    }

    public var repeatType: RepeatType { RepeatType(rawValue: repeatTypeRaw) ?? .none }
    public var status: TaskStatus { TaskStatus(rawValue: statusRaw) ?? .pending }
    public var phase: TaskPhase { TaskPhase(rawValue: phaseRaw) ?? .start }
    public var isRecurring: Bool { repeatType != .none }

    /// 转成纯数据结构做调度计算。
    public var data: TaskData {
        TaskData(
            title: title, remindAt: remindAt, durationMinutes: durationMinutes,
            allDay: allDay, repeatType: repeatType, repeatDays: repeatDays,
            repeatTimes: repeatTimes, status: status, phase: phase,
            nextRemindAt: nextRemindAt, doneAt: doneAt
        )
    }

    /// 把调度计算结果写回模型。
    public func apply(_ d: TaskData) {
        title = d.title
        remindAt = d.remindAt
        durationMinutes = d.durationMinutes
        allDay = d.allDay
        repeatTypeRaw = d.repeatType.rawValue
        repeatDays = d.repeatDays
        repeatTimes = d.repeatTimes
        statusRaw = d.status.rawValue
        phaseRaw = d.phase.rawValue
        nextRemindAt = d.nextRemindAt
        doneAt = d.doneAt
    }

    /// 列表行的说明文字,如"今天 21:00 · 每天 07:00/21:00 · 45 分钟"。
    public var caption: String {
        var parts = [Self.format(nextRemindAt)]
        if isRecurring {
            parts.append(data.repeatLabel)
        } else if allDay {
            parts.append("全天")
        }
        if durationMinutes > 0 { parts.append("\(durationMinutes) 分钟") }
        if phase == .end { parts.append("进行中") }
        return parts.joined(separator: " · ")
    }

    public static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(time)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
