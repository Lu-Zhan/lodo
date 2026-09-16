import Foundation

/// 菜单的纯逻辑层:菜品的值类型 + 按分类分组 + 已选合计 + 给服务员看的那份清单。
/// 和 `TravelPlan` 一样只吃值快照(`MenuDishEntry`),不碰 SwiftData 上下文,
/// 所以单测不用模拟器也能跑。

/// 一道菜的值快照(由 `MenuDish` 转出来)。
public struct MenuDishEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let originalName: String
    public let translatedName: String
    public let intro: String
    public let category: String
    public let price: Double?
    public let selected: Bool
    public let sortIndex: Int

    public init(id: UUID, originalName: String, translatedName: String = "",
                intro: String = "", category: String = "", price: Double? = nil,
                selected: Bool = false, sortIndex: Int = 0) {
        self.id = id
        self.originalName = originalName
        self.translatedName = translatedName
        self.intro = intro
        self.category = category
        self.price = price
        self.selected = selected
        self.sortIndex = sortIndex
    }

    /// 列表主标题:优先译名(用户看得懂的那个),没译名就退回原名。
    public var displayName: String {
        translatedName.isEmpty ? originalName : translatedName
    }

    /// 是否还要单独显示一行原文。菜单本来就是应用内语言时译名与原名一样,
    /// 再重复一行纯属噪声;点单页(给服务员看的那张)例外,那里永远显示原文。
    public var showsOriginal: Bool {
        !originalName.isEmpty && originalName != displayName
    }

    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return originalName.localizedStandardContains(query)
            || translatedName.localizedStandardContains(query)
            || intro.localizedStandardContains(query)
            || category.localizedStandardContains(query)
    }
}

extension MenuDishEntry {
    public init(from dish: MenuDish) {
        self.init(id: dish.uuid, originalName: dish.originalName,
                  translatedName: dish.translatedName, intro: dish.intro,
                  category: dish.category, price: dish.price,
                  selected: dish.selected, sortIndex: dish.sortIndex)
    }
}

/// 一个分类下的菜(前菜、主菜、甜点…)。`category` 为空串表示"没分类",
/// UI 渲染成「其他」——这里不塞中文字面量,菜单的分类名跟着应用内语言走。
public struct MenuCourse: Equatable, Sendable, Identifiable {
    public let category: String
    public let dishes: [MenuDishEntry]
    public var id: String { category }

    public init(category: String, dishes: [MenuDishEntry]) {
        self.category = category
        self.dishes = dishes
    }
}

public enum MenuPlan {

    // MARK: - 分组与排序

    /// 按分类分组。分类的先后顺序按它**第一次出现**的位置(也就是菜单上的顺序),
    /// 不按字母排——菜单本来就是"前菜在前、甜点在后"的,重排一遍反而找不着了;
    /// 没分类的一律收在最后一组(category 为空串)。
    public static func group(_ dishes: [MenuDishEntry]) -> [MenuCourse] {
        let ordered = sorted(dishes)
        var order: [String] = []
        var buckets: [String: [MenuDishEntry]] = [:]
        for dish in ordered {
            let key = dish.category.trimmingCharacters(in: .whitespacesAndNewlines)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(dish)
        }
        // 没分类的那组挪到最后,其余保持首次出现的顺序。
        let named = order.filter { !$0.isEmpty }
        let tail = order.contains("") ? [""] : []
        return (named + tail).map { MenuCourse(category: $0, dishes: buckets[$0] ?? []) }
    }

    /// 排序:按菜单上的顺序(sortIndex),同序号按原名兜底,保证输出稳定。
    public static func sorted(_ dishes: [MenuDishEntry]) -> [MenuDishEntry] {
        dishes.sorted {
            $0.sortIndex != $1.sortIndex
                ? $0.sortIndex < $1.sortIndex
                : $0.originalName < $1.originalName
        }
    }

    /// 已经勾上的菜,按菜单顺序。
    public static func selected(_ dishes: [MenuDishEntry]) -> [MenuDishEntry] {
        sorted(dishes.filter(\.selected))
    }

    // MARK: - 价格

    /// 合计。没标价的菜不参与;**一道标价的都没有时返回 nil**,由 UI 决定不显示
    /// 合计那一行——返回 0 会让人以为"这几道菜是免费的"。
    public static func total(_ dishes: [MenuDishEntry]) -> Double? {
        let prices = dishes.compactMap(\.price)
        guard !prices.isEmpty else { return nil }
        return prices.reduce(0, +)
    }

    /// 合计后面那句说明用的:有几道菜没标价(合计里没算它们)。
    public static func unpricedCount(_ dishes: [MenuDishEntry]) -> Int {
        dishes.filter { $0.price == nil }.count
    }

    /// 价格的展示串。菜单上的价格基本都是整数,整数就不拖 ".00" 这条尾巴;
    /// 币种未知(菜单上只有 ¥ 符号、AI 也认不出来)时只给数字。
    public static func priceText(_ value: Double, currency: String?) -> String {
        let number = value == value.rounded()
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
        guard let currency, !currency.isEmpty else { return number }
        return "\(currency) \(number)"
    }

    // MARK: - 给服务员看 / 落进记忆库

    /// 点单清单的纯文本(复制/分享出去的那份)。每行是"原文 (译名)"——**原文在前**,
    /// 这份是给服务员看的,他看得懂的是菜单上印的那个名字。
    public static func orderText(_ dishes: [MenuDishEntry], currency: String? = nil) -> String {
        let lines = selected(dishes).map { dish -> String in
            var line = dish.originalName.isEmpty ? dish.displayName : dish.originalName
            if dish.showsOriginal || dish.originalName.isEmpty {
                line += "(\(dish.displayName))"
            }
            if let price = dish.price {
                line += " · " + priceText(price, currency: currency)
            }
            return line
        }
        return lines.joined(separator: "\n")
    }

    /// 菜单这条记忆条目的正文(`MemoryItem.sourceText`):整理出来的菜品清单 +
    /// 拍照 OCR 的原文。两份都留:清单让"问 AI"命中得准,原文让识别错的字
    /// 还有迹可循(截断由调用方用 `MemorySearch.truncate` 统一做)。
    public static func searchText(
        restaurant: String, dishes: [MenuDishEntry], rawText: String
    ) -> String {
        var parts: [String] = []
        if !restaurant.isEmpty { parts.append(restaurant) }
        parts.append(contentsOf: sorted(dishes).map { dish in
            [dish.originalName, dish.translatedName, dish.category, dish.intro]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        })
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRaw.isEmpty {
            parts.append("原文:")
            parts.append(trimmedRaw)
        }
        return parts.joined(separator: "\n")
    }
}

/// `DeepSeekClient.parseMenu` 的返回:从一段菜单文字里整理出来、**还没落库**的
/// 一道菜。
public struct ParsedMenuDish: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let originalName: String
    public let translatedName: String
    public let intro: String
    public let category: String
    public let price: Double?

    public init(originalName: String, translatedName: String = "", intro: String = "",
                category: String = "", price: Double? = nil) {
        self.originalName = originalName
        self.translatedName = translatedName
        self.intro = intro
        self.category = category
        self.price = price
    }
}

/// 一整张菜单的解析结果。
public struct ParsedMenu: Equatable, Sendable {
    /// 店名。菜单上没印就是空串,由调用方兜底成"未命名菜单"。
    public let restaurant: String
    /// 菜单原文是什么语言(AI 给的人话,如"日语"),空串表示认不出来。
    public let sourceLanguage: String
    /// ISO 4217 币种码;菜单上只有符号、认不出来时为 nil。
    public let currency: String?
    public let dishes: [ParsedMenuDish]

    public init(restaurant: String = "", sourceLanguage: String = "",
                currency: String? = nil, dishes: [ParsedMenuDish]) {
        self.restaurant = restaurant
        self.sourceLanguage = sourceLanguage
        self.currency = currency
        self.dishes = dishes
    }
}
