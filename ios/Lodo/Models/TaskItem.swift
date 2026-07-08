import Foundation
import SwiftData
import LodoCore

/// SwiftData 持久化模型,字段与 web 版 tasks 表对齐;调度计算通过 TaskData 互转交给 LodoCore。
@Model
final class TaskItem {
    @Attribute(.unique) var uuid: UUID
    var title: String
    var remindAt: Date
    var durationMinutes: Int
    var allDay: Bool
    var repeatTypeRaw: String
    var repeatDays: [Int]
    var repeatTimes: [String]
    var statusRaw: String
    var phaseRaw: String
    var nextRemindAt: Date
    var createdAt: Date
    var doneAt: Date?
    /// 导出到系统提醒事项后的 EKReminder identifier(或导入来源),用于去重与更新。
    var ekIdentifier: String?

    init(
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

    var repeatType: RepeatType { RepeatType(rawValue: repeatTypeRaw) ?? .none }
    var status: TaskStatus { TaskStatus(rawValue: statusRaw) ?? .pending }
    var phase: TaskPhase { TaskPhase(rawValue: phaseRaw) ?? .start }
    var isRecurring: Bool { repeatType != .none }

    /// 转成 LodoCore 的纯数据结构做调度计算。
    var data: TaskData {
        TaskData(
            title: title, remindAt: remindAt, durationMinutes: durationMinutes,
            allDay: allDay, repeatType: repeatType, repeatDays: repeatDays,
            repeatTimes: repeatTimes, status: status, phase: phase,
            nextRemindAt: nextRemindAt, doneAt: doneAt
        )
    }

    /// 把调度计算结果写回模型。
    func apply(_ d: TaskData) {
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
    var caption: String {
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

    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(time)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
