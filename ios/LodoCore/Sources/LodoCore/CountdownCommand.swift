import Foundation

/// AI 对倒数日的一次操作(`create_countdown` / `update_countdown` / `delete_countdown`)。
/// 和 `edit_trip` 同一个取舍:**直接执行**(用户已经说清要加哪天、改成哪天),结果卡片
/// 带撤销;一句话里可以有好几条倒数日操作,但不和待办写操作混在一起(混着时丢掉,
/// 见 parseCommand 的归一化)。
public enum CountdownOp: Equatable, Sendable {
    case create(CountdownDraft)
    case update(id: UUID, change: CountdownChange)
    case delete(id: UUID)
}

/// 新建一个倒数日要的字段。
public struct CountdownDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date?
    public var allDay: Bool
    public var startReminders: [Int]
    public var endReminders: [Int]
    /// nil = 没提,按"还有空位就放上小组件"处理(由 app 层决定);false = 明确不要。
    public var showInWidget: Bool?
    public var notes: String

    public init(title: String, start: Date, end: Date? = nil, allDay: Bool = true,
                startReminders: [Int] = [], endReminders: [Int] = [],
                showInWidget: Bool? = nil, notes: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
        self.notes = notes
    }
}

/// 修改一个倒数日:只带要改的字段,nil = 不动。
public struct CountdownChange: Equatable, Sendable {
    public enum EndChange: Equatable, Sendable {
        case set(Date)
        /// 去掉结束时间(变成只有一个日子)。
        case clear
    }
    public var title: String?
    public var start: Date?
    public var end: EndChange?
    public var allDay: Bool?
    public var startReminders: [Int]?
    public var endReminders: [Int]?
    public var showInWidget: Bool?
    public var notes: String?

    public init(title: String? = nil, start: Date? = nil, end: EndChange? = nil,
                allDay: Bool? = nil, startReminders: [Int]? = nil, endReminders: [Int]? = nil,
                showInWidget: Bool? = nil, notes: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.startReminders = startReminders
        self.endReminders = endReminders
        self.showInWidget = showInWidget
        self.notes = notes
    }

    public var isEmpty: Bool { self == CountdownChange() }
}

/// 一次倒数日操作执行完的记录:结果卡片据此列出改了什么,撤销也靠它——
/// 新建的记 uuid(撤销时删掉),改过/删掉的记整份改之前的快照(撤销时写回)。
/// 存进 `AgentMessage.countdownSnapshotData`。
public struct CountdownEditRecord: Codable, Equatable, Sendable {
    public var created: [BackupCountdownEvent]
    public var updatedBefore: [BackupCountdownEvent]
    public var updatedAfter: [BackupCountdownEvent]
    public var deleted: [BackupCountdownEvent]
    /// 没做成的(找不到那一件、小组件已经满了……),卡片上如实列出。
    public var skipped: [String]
    public var reverted: Bool?

    public init(created: [BackupCountdownEvent] = [], updatedBefore: [BackupCountdownEvent] = [],
                updatedAfter: [BackupCountdownEvent] = [], deleted: [BackupCountdownEvent] = [],
                skipped: [String] = [], reverted: Bool? = nil) {
        self.created = created
        self.updatedBefore = updatedBefore
        self.updatedAfter = updatedAfter
        self.deleted = deleted
        self.skipped = skipped
        self.reverted = reverted
    }

    public var hasChanges: Bool { !created.isEmpty || !updatedAfter.isEmpty || !deleted.isEmpty }

    /// 存进消息 content 的纯文字版:对话历史只回传 content,模型接着说"改成下周五"
    /// 时要知道刚才动的是哪一件。固定中文,同其他喂给模型的文字。
    public var transcript: String {
        func line(_ event: BackupCountdownEvent) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = event.allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            var text = "「\(event.title)」\(formatter.string(from: event.startDate))"
            if let end = event.endDate { text += " 至 \(formatter.string(from: end))" }
            return text
        }
        var parts: [String] = []
        if !created.isEmpty { parts.append("新建倒数日:" + created.map(line).joined(separator: "、")) }
        if !updatedAfter.isEmpty { parts.append("修改倒数日:" + updatedAfter.map(line).joined(separator: "、")) }
        if !deleted.isEmpty { parts.append("删除倒数日:" + deleted.map(\.title).joined(separator: "、")) }
        if reverted == true { parts.append("(已撤销)") }
        return parts.isEmpty ? "倒数日没有改动。" : parts.joined(separator: ";")
    }
}

extension DeepSeekClient {
    /// 倒数日在 prompt 里的清单(带 id,修改/删除时要原样引用)。
    static func countdownList(_ entries: [CountdownEntry]) -> [[String: Any]] {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        let dateTime = DateFormatter()
        dateTime.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.map { entry in
            let formatter = entry.allDay ? date : dateTime
            var fields: [String: Any] = [
                "id": entry.id.uuidString, "title": entry.title,
                "start": formatter.string(from: entry.start), "all_day": entry.allDay,
                "show_in_widget": entry.showInWidget,
            ]
            if let end = entry.end { fields["end"] = formatter.string(from: end) }
            if !entry.startReminders.isEmpty { fields["start_reminders"] = entry.startReminders }
            if !entry.endReminders.isEmpty { fields["end_reminders"] = entry.endReminders }
            return fields
        }
    }

    /// 解析一条倒数日操作(单测入口)。`validIDs` 是当前倒数日的 id,修改/删除时校验。
    static func parseCountdownOp(_ raw: [String: Any], action: String,
                                 validIDs: [String]) throws -> CountdownOp {
        func text(_ key: String) -> String? {
            guard let value = (raw[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func bool(_ key: String) -> Bool? {
            if let value = raw[key] as? Bool { return value }
            if let value = raw[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
            return nil
        }
        /// 提醒:分钟数数组,负数/重复去掉,最多 6 个。
        func reminders(_ key: String) -> [Int]? {
            guard let list = raw[key] as? [Any] else { return nil }
            let minutes = list.compactMap { element -> Int? in
                if let value = element as? Int { return value }
                if let value = element as? Double { return Int(value) }
                return (element as? String).flatMap { Int($0) }
            }.filter { $0 >= 0 }
            return Array(Array(Set(minutes)).sorted().prefix(6))
        }
        func id() throws -> UUID {
            var string = text("id") ?? ""
            if string.hasPrefix("[id:") { string = String(string.dropFirst(4).dropLast()) }
            guard validIDs.contains(string), let uuid = UUID(uuidString: string) else {
                throw DeepSeekError.parse("找不到要操作的倒数日")
            }
            return uuid
        }

        switch action {
        case "create_countdown":
            guard let title = text("title") else {
                throw DeepSeekError.parse("返回格式异常:倒数日缺少名称")
            }
            guard let startText = text("start"), let start = countdownDate(startText) else {
                throw DeepSeekError.parse("返回格式异常:倒数日缺少日期")
            }
            // 没写 all_day 时看日期里有没有时刻。
            let allDay = bool("all_day") ?? !startText.contains(":")
            var end = text("end").flatMap(countdownDate)
            if let value = end, value < start { end = nil }
            return .create(CountdownDraft(
                title: title, start: start, end: end, allDay: allDay,
                startReminders: reminders("start_reminders") ?? [],
                endReminders: end == nil ? [] : (reminders("end_reminders") ?? []),
                showInWidget: bool("show_in_widget"), notes: text("notes") ?? ""))
        case "update_countdown":
            let target = try id()
            var change = CountdownChange()
            change.title = text("title")
            change.start = text("start").flatMap(countdownDate)
            if raw["end"] is NSNull || (raw["end"] as? String)?.trimmingCharacters(in: .whitespaces) == "" {
                change.end = .clear
            } else if let end = text("end").flatMap(countdownDate) {
                change.end = .set(end)
            }
            change.allDay = bool("all_day")
            change.startReminders = reminders("start_reminders")
            change.endReminders = reminders("end_reminders")
            change.showInWidget = bool("show_in_widget")
            change.notes = raw["notes"] as? String
            guard !change.isEmpty else {
                throw DeepSeekError.parse("返回格式异常:倒数日没有要改的内容")
            }
            return .update(id: target, change: change)
        default:
            return .delete(id: try id())
        }
    }

    /// "yyyy-MM-dd" 或 "yyyy-MM-dd HH:mm"(本机时区)。
    static func countdownDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = text.contains(":") ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
