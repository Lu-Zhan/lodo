import Foundation

/// AI「调整行程」(`edit_trip`)的一次改动:对**已经记下**的某次旅行删几项、加几项、
/// 改几项。和 `plan_trip` 不同,这条**直接执行**——用户已经指名道姓说了哪天要怎么
/// 改,再出一张确认卡没带来信息量;执行结果卡片上带撤销兜底(同单条修改待办)。
public struct TripEdit: Codable, Equatable, Sendable {
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
public struct TripEditUpdate: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String?
    public var note: String?
    public var start: Date?
    public var end: Date?
    public var placeName: String?
    /// 费用(门票、房费、机票价……),**这一项的总价**(消费页按总价加)。给已经记下的
    /// 行程项补/改花了多少钱走这两个字段。
    public var price: Double?
    public var currency: String?
    /// 用户报的是每晚的价格(「一晚 800」):app 按记下的入住晚数乘成总价(`resolvedPrice`),
    /// 不让模型自己乘——它会把单价直接当总价存(实测 3/3)。
    public var pricePerNight: Double?

    public init(id: UUID, title: String? = nil, note: String? = nil, start: Date? = nil,
                end: Date? = nil, placeName: String? = nil, price: Double? = nil,
                currency: String? = nil, pricePerNight: Double? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.start = start
        self.end = end
        self.placeName = placeName
        self.price = price
        self.currency = currency
        self.pricePerNight = pricePerNight
    }

    public var isEmpty: Bool {
        title == nil && note == nil && start == nil && end == nil && placeName == nil
            && price == nil && currency == nil && pricePerNight == nil
    }

    /// 写进这一项的总价。给了总价就用总价;只给了每晚价格时按入住晚数乘(住宿才有"晚",
    /// 别的类型当成总价;没记退房时间、或者算出来不到一晚按一晚)。都没给返回 nil(价格不动)。
    /// start/end 用**改完之后**的入住/退房时间。
    public func resolvedPrice(kind: TravelItemKind, start: Date?, end: Date?,
                              calendar: Calendar = .current) -> Double? {
        if let price { return price }
        guard let pricePerNight else { return nil }
        guard kind == .lodging, let start, let end else { return pricePerNight }
        let nights = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                             to: calendar.startOfDay(for: end)).day ?? 0
        return pricePerNight * Double(max(nights, 1))
    }

    /// 只补/改费用和备注,不动时间、地点、名称。航班允许这一种改法:时刻和座位来自订单不让 AI
    /// 动,但"机票花了 3200"是用户自己说的事实,该记得上。
    public var touchesOnlyCostOrNote: Bool {
        title == nil && start == nil && end == nil && placeName == nil
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
    /// 改完之后的费用(卡片上显示;老记录里没有这两个字段,解出来是 nil)。
    public var price: Double?
    public var currency: String?

    public init(id: UUID, kind: TravelItemKind, title: String, start: Date?,
                price: Double? = nil, currency: String? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.start = start
        self.price = price
        self.currency = currency
    }

    public var kind: TravelItemKind { TravelItemKind(rawValue: kindRaw) ?? .place }
}
