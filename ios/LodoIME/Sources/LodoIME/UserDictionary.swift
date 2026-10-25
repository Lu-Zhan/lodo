import Foundation

/// 用户词:上屏过的词和整句,按音节序列记次数。存键盘自己的容器,不需要完全访问。
public struct UserDictionary: Codable, Sendable {
    struct Item: Codable, Sendable {
        var count: Double
        var lastUsed: Date
    }

    /// 音节编号序列(逗号连接)→ 词 → 记录。
    private var items: [String: [String: Item]] = [:]
    /// 所有学过的序列的前缀:词图搜索在词库里走不下去时,靠它判断要不要继续往下找用户整句。
    /// 只在新增音节键时增量加、删改时整体重建——上屏是打字路径,不能每次都扫全表。
    private var prefixes: Set<String> = []
    /// 词条数(所有音节键下的词加起来),容量按它算。
    private var entryCount = 0

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: CodingKeys.self).decode([String: [String: Item]].self, forKey: .items)
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        prefixes = []
        for k in items.keys { addPrefixes(of: k) }
        entryCount = items.values.reduce(0) { $0 + $1.count }
    }

    private mutating func addPrefixes(of key: String) {
        let parts = key.split(separator: ",")
        for n in 1...max(parts.count, 1) { prefixes.insert(parts.prefix(n).joined(separator: ",")) }
    }

    func hasPhrase(withPrefix ids: [UInt16]) -> Bool { prefixes.contains(Self.key(ids)) }
    /// 只留最常用的这么多条(词条数),超了按"次数 × 新近程度"淘汰到一半。
    public static let capacity = 20_000
    /// 半衰期:一个月不用,权重减半。
    static let halfLife: TimeInterval = 30 * 24 * 3600

    public init() {}

    static func key(_ ids: [UInt16]) -> String { ids.map(String.init).joined(separator: ",") }

    public var isEmpty: Bool { items.isEmpty }

    public mutating func learn(_ word: String, ids: [UInt16], now: Date = Date()) {
        guard !word.isEmpty, !ids.isEmpty else { return }
        let k = Self.key(ids)
        if items[k] == nil { addPrefixes(of: k) }
        let existing = items[k]?[word]
        if existing == nil { entryCount += 1 }
        var item = existing ?? Item(count: 0, lastUsed: now)
        item.count = Self.decayed(item, now: now) + 1
        item.lastUsed = now
        items[k, default: [:]][word] = item
        if entryCount > Self.capacity { prune(now: now) }
    }

    public mutating func forget(_ word: String, ids: [UInt16]) {
        let k = Self.key(ids)
        guard items[k]?[word] != nil else { return }
        items[k]?[word] = nil
        if items[k]?.isEmpty == true { items[k] = nil }
        rebuildIndex()
    }

    /// 这个音节序列下学过的词和它们的代价加成(越常用越低)。
    func words(for ids: [UInt16], now: Date) -> [(word: String, cost: Int)] {
        guard let bucket = items[Self.key(ids)] else { return [] }
        return bucket.map { word, item in
            let weight = Self.decayed(item, now: now)
            // 用过一次 ≈ 一个中频词;用得越多越靠前,但封顶,免得永远压住词典首选。
            return (word, max(150, 900 - Int(250 * log2(1 + weight))))
        }
    }

    static func decayed(_ item: Item, now: Date) -> Double {
        item.count * pow(0.5, max(0, now.timeIntervalSince(item.lastUsed)) / halfLife)
    }

    private mutating func prune(now: Date) {
        let flat = items.flatMap { k, bucket in bucket.map { (k, $0.key, Self.decayed($0.value, now: now)) } }
            .sorted { $0.2 > $1.2 }
        var kept: [String: [String: Item]] = [:]
        for (k, w, _) in flat.prefix(Self.capacity / 2) { kept[k, default: [:]][w] = items[k]?[w] }
        items = kept
        rebuildIndex()
    }
}
