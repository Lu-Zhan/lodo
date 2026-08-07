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
    /// 这件事属于哪个项目/主题,AI 新建时自动推断、用户可在表单里改;纯展示/
    /// 组织用的分类信息,不参与调度(不进 TaskData/Scheduler)。
    public var project: String?

    // 记忆"转为待办"携带的内容快照,展平存储(与 attachment 计算属性配套);
    // 直接新建的待办这几个字段都是 nil。同样出于 CloudKit 同步要求,不给默认值
    // (nil 就是默认值,和 doneAt/ekIdentifier 的写法一致)。
    public var attachmentKindRaw: String?
    public var attachmentTitle: String?
    public var attachmentSummary: String?
    public var attachmentText: String?
    public var attachmentURLString: String?
    public var attachmentFileName: String?

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
        ekIdentifier: String? = nil,
        project: String? = nil
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
        self.project = project
    }

    public var repeatType: RepeatType { RepeatType(rawValue: repeatTypeRaw) ?? .none }
    public var status: TaskStatus { TaskStatus(rawValue: statusRaw) ?? .pending }
    public var phase: TaskPhase { TaskPhase(rawValue: phaseRaw) ?? .start }
    public var isRecurring: Bool { repeatType != .none }

    /// 展平字段 ↔ TaskAttachment 的桥接;nil = 直接新建的待办(无附件)。
    public var attachment: TaskAttachment? {
        get {
            guard let kindRaw = attachmentKindRaw, let kind = MemoryKind(rawValue: kindRaw) else {
                return nil
            }
            return TaskAttachment(
                kind: kind, title: attachmentTitle ?? "", summary: attachmentSummary ?? "",
                text: attachmentText ?? "", urlString: attachmentURLString,
                originalFileName: attachmentFileName)
        }
        set {
            attachmentKindRaw = newValue?.kind.rawValue
            attachmentTitle = newValue?.title
            attachmentSummary = newValue?.summary
            attachmentText = newValue?.text
            attachmentURLString = newValue?.urlString
            attachmentFileName = newValue?.originalFileName
        }
    }

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
