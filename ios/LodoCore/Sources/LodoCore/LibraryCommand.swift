import Foundation

// AI 助手对「资产」与「新闻订阅」的写操作(仅 iOS)。和倒数日同一个取舍:**直接执行**
// (用户已经说清要记哪一项、订哪个源),结果卡片带撤销;可以和待办等别的操作
// 混在一句话里,两样都做(不参与 parseCommand 里问答类的归一化)。

/// 资产台账的一次操作(`create_asset` / `update_asset`)。只管资产/负债条目
/// (记忆库里打「资产」标签的那些),收入/固定支出/信用卡仍在资产页右上角手动加。
public enum AssetOp: Equatable, Sendable {
    case create(AssetDraft)
    case update(id: UUID, change: AssetChange)
}

public struct AssetDraft: Equatable, Sendable {
    public var title: String
    /// 分类(`AssetCategory.presets` 之一或自定义);空串 = 「其他」。
    public var category: String
    public var value: Double?
    public var currency: String
    public var liability: Double?
    public var interestRate: Double?
    public var note: String

    public init(title: String, category: String = "", value: Double? = nil, currency: String = "CNY",
                liability: Double? = nil, interestRate: Double? = nil, note: String = "") {
        self.title = title
        self.category = category
        self.value = value
        self.currency = currency
        self.liability = liability
        self.interestRate = interestRate
        self.note = note
    }
}

/// 修改一项资产:只带要改的字段,nil = 不动。
public struct AssetChange: Equatable, Sendable {
    public var title: String?
    public var category: String?
    public var value: Double?
    public var currency: String?
    public var liability: Double?
    public var interestRate: Double?
    public var note: String?

    public init(title: String? = nil, category: String? = nil, value: Double? = nil,
                currency: String? = nil, liability: Double? = nil, interestRate: Double? = nil,
                note: String? = nil) {
        self.title = title
        self.category = category
        self.value = value
        self.currency = currency
        self.liability = liability
        self.interestRate = interestRate
        self.note = note
    }

    public var isEmpty: Bool { self == AssetChange() }
}

/// prompt 里资产清单的一行(值快照,app 层从 MemoryItem 取)。
public struct AssetEntry: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let category: String
    public let value: Double?
    public let currency: String
    public let liability: Double?
    public let interestRate: Double?
    public let updatedAt: Date

    public init(id: UUID, title: String, category: String, value: Double?, currency: String,
                liability: Double?, interestRate: Double?, updatedAt: Date) {
        self.id = id
        self.title = title
        self.category = category
        self.value = value
        self.currency = currency
        self.liability = liability
        self.interestRate = interestRate
        self.updatedAt = updatedAt
    }
}

/// 新闻订阅的一次操作(`subscribe_feed` / `update_feed`)。
public enum FeedOp: Equatable, Sendable {
    case subscribe(FeedDraft)
    case update(id: UUID, change: FeedChange)
}

/// 订阅一个源。`url` 和 `name` 至少有一个:有链接(feed 本身或网站首页)先按链接订,
/// 只有名字时按名字在推荐源和已有订阅里模糊找(`FeedMatch`)。
public struct FeedDraft: Equatable, Sendable {
    public var url: String?
    public var name: String?
    public var kind: NewsFeedKind

    public init(url: String? = nil, name: String? = nil, kind: NewsFeedKind = .news) {
        self.url = url
        self.name = name
        self.kind = kind
    }

    /// 结果卡片、报错里怎么称呼这一条。
    public var label: String { name ?? url ?? "" }
}

public struct FeedChange: Equatable, Sendable {
    public var title: String?
    public var kind: NewsFeedKind?
    public var enabled: Bool?

    public init(title: String? = nil, kind: NewsFeedKind? = nil, enabled: Bool? = nil) {
        self.title = title
        self.kind = kind
        self.enabled = enabled
    }

    public var isEmpty: Bool { self == FeedChange() }
}

/// prompt 里订阅清单的一行。
public struct FeedEntry: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: String
    public let kind: NewsFeedKind
    public let enabled: Bool

    public init(id: UUID, title: String, url: String, kind: NewsFeedKind, enabled: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.kind = kind
        self.enabled = enabled
    }
}

/// 一次资产/订阅操作执行完的记录:卡片据此列出改了什么,撤销也靠它——新建的记
/// uuid(撤销时删掉),改过的记整份改之前的快照(撤销时写回)。存进
/// `AgentMessage.librarySnapshotData`。
public struct LibraryEditRecord: Codable {
    public enum Domain: String, Codable, Sendable { case asset, feed }

    /// 卡片上的一行。
    public struct Line: Codable, Equatable, Sendable {
        public var domain: Domain
        public var created: Bool
        public var uuid: UUID
        public var title: String
        public var detail: String

        public init(domain: Domain, created: Bool, uuid: UUID, title: String, detail: String) {
            self.domain = domain
            self.created = created
            self.uuid = uuid
            self.title = title
            self.detail = detail
        }
    }

    public var lines: [Line]
    public var assetsBefore: [BackupMemoryItem]
    public var feedsBefore: [BackupNewsFeed]
    /// 没做成的(找不到订阅地址、已经订过、找不到那一项……),卡片上如实列出。
    public var skipped: [String]
    public var reverted: Bool?

    public init(lines: [Line] = [], assetsBefore: [BackupMemoryItem] = [],
                feedsBefore: [BackupNewsFeed] = [], skipped: [String] = [], reverted: Bool? = nil) {
        self.lines = lines
        self.assetsBefore = assetsBefore
        self.feedsBefore = feedsBefore
        self.skipped = skipped
        self.reverted = reverted
    }

    public var hasChanges: Bool { !lines.isEmpty }

    /// 存进消息 content 的纯文字版(对话历史只回传 content)。固定中文,同其他喂给模型的文字。
    public var transcript: String {
        func part(_ domain: Domain, created: Bool, _ prefix: String) -> String? {
            let titles = lines.filter { $0.domain == domain && $0.created == created }
                .map { "「\($0.title)」" + ($0.detail.isEmpty ? "" : $0.detail) }
            return titles.isEmpty ? nil : prefix + titles.joined(separator: "、")
        }
        var parts = [part(.asset, created: true, "新增资产:"), part(.asset, created: false, "修改资产:"),
                     part(.feed, created: true, "新增订阅:"), part(.feed, created: false, "修改订阅:")]
            .compactMap { $0 }
        if !skipped.isEmpty { parts.append("没做成:" + skipped.joined(separator: "、")) }
        if reverted == true { parts.append("(已撤销)") }
        return parts.isEmpty ? "资产和订阅没有改动。" : parts.joined(separator: ";")
    }
}

/// 按名字模糊找订阅源:用户说"订阅少数派""把 hacker news 停了"时,名字和源的标题/
/// 地址对得上几分。纯函数,app 层拿推荐源和已有订阅来比。
public enum FeedMatch {
    /// 0 = 对不上;越大越像。完全相同 > 一方包含另一方 > 地址里包含。
    public static func score(query: String, title: String, url: String) -> Int {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let t = normalize(title)
        if q == t { return 100 }
        if !t.isEmpty, t.contains(q) || q.contains(t) {
            // 短的那一边占长的越多越像,免得「新闻」这种词和谁都沾边。
            let ratio = Double(min(q.count, t.count)) / Double(max(q.count, t.count))
            return ratio >= 0.3 ? 50 + Int(ratio * 40) : 0
        }
        let host = normalize(URL(string: url)?.host ?? url)
        if q.count >= 3, host.contains(q) { return 40 }
        return 0
    }

    /// 在候选里挑最像的一个(分数最高,并列取先出现的);都对不上返回 nil。
    public static func best<T>(_ query: String, in candidates: [T],
                               title: (T) -> String, url: (T) -> String) -> T? {
        var best: (T, Int)?
        for candidate in candidates {
            let value = score(query: query, title: title(candidate), url: url(candidate))
            if value > 0, value > (best?.1 ?? 0) { best = (candidate, value) }
        }
        return best?.0
    }

    /// 小写、去空白标点,「Hacker News」「hackernews」「HN 新闻」里的前两个视为同一个。
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}

extension DeepSeekClient {
    /// 资产在 prompt 里的清单(带 id,修改时要原样引用)。
    static func assetList(_ entries: [AssetEntry]) -> [[String: Any]] {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        return entries.map { entry in
            var fields: [String: Any] = [
                "id": entry.id.uuidString, "title": entry.title, "category": entry.category,
                "currency": entry.currency, "updated": date.string(from: entry.updatedAt),
            ]
            if let value = entry.value { fields["value"] = value }
            if let liability = entry.liability { fields["liability"] = liability }
            if let rate = entry.interestRate { fields["interest_rate"] = rate }
            return fields
        }
    }

    /// 订阅在 prompt 里的清单(带 id)。
    static func feedList(_ entries: [FeedEntry]) -> [[String: Any]] {
        entries.map { entry in
            var fields: [String: Any] = [
                "id": entry.id.uuidString, "title": entry.title, "url": entry.url,
                "kind": entry.kind.rawValue,
            ]
            if !entry.enabled { fields["enabled"] = false }
            return fields
        }
    }

    private static func libraryText(_ raw: [String: Any], _ key: String) -> String? {
        guard let value = (raw[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func libraryNumber(_ raw: [String: Any], _ key: String) -> Double? {
        if let value = raw[key] as? Double { return value }
        if let value = raw[key] as? Int { return Double(value) }
        if let text = raw[key] as? String {
            return Double(text.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func libraryID(_ raw: [String: Any], validIDs: [String], what: String) throws -> UUID {
        var string = libraryText(raw, "id") ?? ""
        if string.hasPrefix("[id:") { string = String(string.dropFirst(4).dropLast()) }
        guard validIDs.contains(string), let uuid = UUID(uuidString: string) else {
            throw DeepSeekError.parse("找不到要修改的\(what)")
        }
        return uuid
    }

    /// 解析一条资产操作(单测入口)。
    static func parseAssetOp(_ raw: [String: Any], action: String,
                             validIDs: [String]) throws -> AssetOp {
        let currency = libraryText(raw, "currency")?.uppercased()
        if action == "create_asset" {
            guard let title = libraryText(raw, "title") else {
                throw DeepSeekError.parse("返回格式异常:资产缺少名称")
            }
            let value = libraryNumber(raw, "value")
            let liability = libraryNumber(raw, "liability")
            guard value != nil || liability != nil else {
                throw DeepSeekError.parse("返回格式异常:资产缺少金额")
            }
            return .create(AssetDraft(
                title: title, category: libraryText(raw, "category") ?? "", value: value,
                currency: currency ?? "CNY", liability: liability,
                interestRate: libraryNumber(raw, "interest_rate"), note: libraryText(raw, "note") ?? ""))
        }
        let id = try libraryID(raw, validIDs: validIDs, what: "资产")
        let change = AssetChange(
            title: libraryText(raw, "title"), category: libraryText(raw, "category"),
            value: libraryNumber(raw, "value"), currency: currency,
            liability: libraryNumber(raw, "liability"),
            interestRate: libraryNumber(raw, "interest_rate"), note: raw["note"] as? String)
        guard !change.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:资产没有要改的内容")
        }
        return .update(id: id, change: change)
    }

    /// 解析订阅操作(单测入口)。`subscribe_feed` 可以是一条,也可以带 `feeds` 数组
    /// 一次订好几个(用户贴了一串链接);返回的是展开后的列表。
    static func parseFeedOps(_ raw: [String: Any], action: String,
                             validIDs: [String]) throws -> [FeedOp] {
        func kind(_ item: [String: Any]) -> NewsFeedKind? {
            libraryText(item, "kind").flatMap { NewsFeedKind(rawValue: $0.lowercased()) }
        }
        if action == "subscribe_feed" {
            let items = (raw["feeds"] as? [[String: Any]]) ?? [raw]
            var seen = Set<String>()
            let drafts = items.compactMap { item -> FeedDraft? in
                let url = libraryText(item, "url")
                let name = libraryText(item, "name") ?? libraryText(item, "title")
                guard url != nil || name != nil else { return nil }
                let key = (url ?? name ?? "").lowercased()
                guard seen.insert(key).inserted else { return nil }
                return FeedDraft(url: url, name: name, kind: kind(item) ?? kind(raw) ?? .news)
            }
            guard !drafts.isEmpty else {
                throw DeepSeekError.parse("返回格式异常:订阅缺少链接或名称")
            }
            return Array(drafts.prefix(20)).map(FeedOp.subscribe)
        }
        let id = try libraryID(raw, validIDs: validIDs, what: "订阅")
        var enabled: Bool?
        if let value = raw["enabled"] as? Bool { enabled = value }
        if let value = raw["enabled"] as? String { enabled = ["true", "yes", "1"].contains(value.lowercased()) }
        let change = FeedChange(title: libraryText(raw, "title"), kind: kind(raw), enabled: enabled)
        guard !change.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:订阅没有要改的内容")
        }
        return [.update(id: id, change: change)]
    }
}
