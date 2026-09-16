import Foundation

/// AI「调整行程」(`edit_trip`)的一次改动:对**已经记下**的某次旅行删几项、加几项、
/// 改几项。和 `plan_trip` 不同,这条**直接执行**——用户已经指名道姓说了哪天要怎么
/// 改,再出一张确认卡没带来信息量;执行结果卡片上带撤销兜底(同单条修改待办)。
public struct TripEdit: Equatable, Sendable {
    /// 旅行名(模型从 read_trip 读到的原名);删/改的 id 能定位到旅行时以 id 为准。
    public var tripTitle: String
    /// 一句话说明这次怎么调整的,结果卡片顶上那行。
    public var summary: String
    public var removeIDs: [UUID]
    public var additions: [TripPlanItem]
    public var updates: [TripEditUpdate]

    public init(tripTitle: String = "", summary: String = "", removeIDs: [UUID] = [],
                additions: [TripPlanItem] = [], updates: [TripEditUpdate] = []) {
        self.tripTitle = tripTitle
        self.summary = summary
        self.removeIDs = removeIDs
        self.additions = additions
        self.updates = updates
    }

    /// 所有引用到的已有行程项 id(删 + 改),用来反推是哪次旅行。
    public var referencedIDs: [UUID] { removeIDs + updates.map(\.id) }
}

/// 改一项已有安排:nil 的字段保持原样。
public struct TripEditUpdate: Equatable, Sendable {
    public var id: UUID
    public var title: String?
    public var note: String?
    public var start: Date?
    public var end: Date?
    public var placeName: String?

    public init(id: UUID, title: String? = nil, note: String? = nil, start: Date? = nil,
                end: Date? = nil, placeName: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.start = start
        self.end = end
        self.placeName = placeName
    }

    public var isEmpty: Bool {
        title == nil && note == nil && start == nil && end == nil && placeName == nil
    }
}

/// 一次调整**执行完之后**的记录,序列化进 `AgentMessage.tripEditSnapshotData`,
/// 供结果卡片展示和撤销。删掉/改掉的行程项存整份 `BackupMemoryItem` 快照
/// (备份功能现成的展平结构 + apply(to:)),撤销就是按快照原 uuid 写回去。
public struct TripEditRecord: Codable {
    public var tripUUID: UUID
    public var tripTitle: String
    public var summary: String
    public var added: [TripEditLine]
    public var removed: [BackupMemoryItem]
    public var updatedBefore: [BackupMemoryItem]
    /// 改完之后的样子(展示用,和 updatedBefore 一一对应)。
    public var updatedAfter: [TripEditLine]
    /// 没动的项:航班、带附件的、找不到的。卡片上如实列出来,不能让用户以为都改了。
    public var skipped: [String]
    public var reverted: Bool?

    public init(tripUUID: UUID, tripTitle: String, summary: String,
                added: [TripEditLine] = [], removed: [BackupMemoryItem] = [],
                updatedBefore: [BackupMemoryItem] = [], updatedAfter: [TripEditLine] = [],
                skipped: [String] = []) {
        self.tripUUID = tripUUID
        self.tripTitle = tripTitle
        self.summary = summary
        self.added = added
        self.removed = removed
        self.updatedBefore = updatedBefore
        self.updatedAfter = updatedAfter
        self.skipped = skipped
    }

    public var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !updatedBefore.isEmpty }

    /// 纯文字版(存进消息 content):对话历史只回传 content,用户接着说
    /// "再把第三天也改一下"时,模型要看得到这次已经改了什么。
    public var transcript: String {
        let time = DateFormatter()
        time.dateFormat = "M月d日 HH:mm"
        func stamp(_ date: Date?) -> String { date.map { "(\(time.string(from: $0)))" } ?? "" }
        var lines = ["已调整「\(tripTitle)」" + (summary.isEmpty ? "" : ":\(summary)")]
        lines += removed.map { "删除:\($0.title)\(stamp($0.travelStart))" }
        lines += added.map { "新增:\($0.title)\(stamp($0.start))" }
        lines += updatedAfter.map { "修改:\($0.title)\(stamp($0.start))" }
        if !skipped.isEmpty { lines.append("没有改动:" + skipped.joined(separator: "、")) }
        if reverted == true { lines.append("(这次调整已撤销)") }
        return lines.joined(separator: "\n")
    }
}

/// 结果卡片上的一行:新增或改过之后的某项。
public struct TripEditLine: Codable, Equatable, Sendable {
    public var id: UUID
    public var kindRaw: String
    public var title: String
    public var start: Date?

    public init(id: UUID, kind: TravelItemKind, title: String, start: Date?) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.start = start
    }

    public var kind: TravelItemKind { TravelItemKind(rawValue: kindRaw) ?? .place }
}
