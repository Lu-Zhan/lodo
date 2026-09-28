import Foundation
import SwiftData

/// 旅行用品清单里的一件东西(护照、充电器、雨伞……)。挂在某次旅行下,靠
/// `tripUUID` 关联、不建 SwiftData 关系(同 `TravelTrip` ↔ 行程项的取舍)。
///
/// 不做成记忆条目:一趟旅行几十件小东西,每件都进记忆库和向量索引只会把
/// 记忆刷爆(同 `MenuDish` 的理由),单件用品也不是值得收藏的资料。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class PackingItem {
    public var uuid: UUID = UUID()
    public var tripUUID: UUID = UUID()
    public var title: String = ""
    /// 分类(证件/衣物/电子/洗护/药品/其他……),空串 = 没分类。
    public var category: String = ""
    /// 已经装进行李。
    public var packed: Bool = false
    /// 同一分类里的先后(添加顺序)。
    public var sortIndex: Int = 0
    public var createdAt: Date = Date.now
    /// 共享旅行里别人加的这件东西:添加人的显示名。自己加的、没共享的为 nil。
    public var sharedAddedBy: String?

    public init(uuid: UUID = UUID(), tripUUID: UUID, title: String, category: String = "",
                packed: Bool = false, sortIndex: Int = 0, createdAt: Date = .now) {
        self.uuid = uuid
        self.tripUUID = tripUUID
        self.title = title
        self.category = category
        self.packed = packed
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// AI 建议的一件用品。
public struct PackingSuggestion: Equatable, Sendable, Identifiable, Hashable {
    public let title: String
    public let category: String
    /// 为什么要带(一句话,可空):"京都十一月早晚凉""有温泉"。
    public let reason: String
    public var id: String { category + "\u{1F}" + title }

    public init(title: String, category: String, reason: String = "") {
        self.title = title
        self.category = category
        self.reason = reason
    }
}

public enum PackingPlan {
    /// 按分类分组,分类按**首次出现的顺序**(同菜单的分类,不按字母重排),
    /// 没分类的收在最后;组内按 sortIndex、再按添加时间。
    public static func grouped(_ items: [PackingItem]) -> [(category: String, items: [PackingItem])] {
        let ordered = items.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        var order: [String] = []
        var buckets: [String: [PackingItem]] = [:]
        for item in ordered {
            let key = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        let named = order.filter { !$0.isEmpty }
        let tail = order.contains("") ? [""] : []
        return (named + tail).map { ($0, buckets[$0] ?? []) }
    }

    /// 去掉已经在清单里的(名字忽略大小写与空白,互相包含也算——"充电器"和
    /// "手机充电器"是同一件)。AI 的建议里自己重复的也只留第一条。
    public static func newSuggestions(_ suggestions: [PackingSuggestion],
                                      existing: [String]) -> [PackingSuggestion] {
        func norm(_ text: String) -> String {
            text.lowercased().filter { !$0.isWhitespace }
        }
        var seen = existing.map(norm).filter { !$0.isEmpty }
        var result: [PackingSuggestion] = []
        for suggestion in suggestions {
            let key = norm(suggestion.title)
            guard !key.isEmpty,
                  !seen.contains(where: { $0.contains(key) || key.contains($0) }) else { continue }
            seen.append(key)
            result.append(suggestion)
        }
        return result
    }
}
