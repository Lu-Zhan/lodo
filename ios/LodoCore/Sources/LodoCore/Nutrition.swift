import Foundation

/// 热量(千卡)+ 三大营养素(克)。
public struct Nutrition: Codable, Equatable, Sendable {
    public var calories: Double
    public var proteinG: Double
    public var fatG: Double
    public var carbsG: Double

    public init(calories: Double = 0, proteinG: Double = 0, fatG: Double = 0, carbsG: Double = 0) {
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
    }

    public static let zero = Nutrition()

    public static func + (a: Nutrition, b: Nutrition) -> Nutrition {
        Nutrition(calories: a.calories + b.calories, proteinG: a.proteinG + b.proteinG,
                  fatG: a.fatG + b.fatG, carbsG: a.carbsG + b.carbsG)
    }
}

/// 一顿饭里的一样东西(「牛肉面 1 碗」)。
public struct NutritionItem: Codable, Equatable, Sendable {
    public var name: String
    /// 份量原样(「1 碗」「250 毫升」),模型没给为空串。
    public var amount: String
    public var nutrition: Nutrition

    public init(name: String, amount: String = "", nutrition: Nutrition) {
        self.name = name
        self.amount = amount
        self.nutrition = nutrition
    }
}

/// `DeepSeekClient.estimateNutrition` 的返回。
public struct NutritionEstimate: Equatable, Sendable {
    public var items: [NutritionItem]
    public var total: Nutrition

    public init(items: [NutritionItem]) {
        self.items = items
        self.total = items.reduce(.zero) { $0 + $1.nutrition }
    }

    /// 解析 AI 返回(单测入口)。
    /// `{"items": [{"name", "amount", "calories", "protein", "fat", "carbs"}]}`
    /// 总量由客户端按逐项相加,不信模型自己给的合计(实测会加错)。一项都没有返回 nil。
    public static func parse(_ payload: [String: Any]) -> NutritionEstimate? {
        let items: [NutritionItem] = (payload["items"] as? [Any] ?? []).compactMap { raw in
            guard let dict = raw as? [String: Any],
                  let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let amount = (dict["amount"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 单样东西给个宽松上限:模型偶尔会吐出离谱的大数,转 Int 显示时会溢出崩溃。
            let nutrition = Nutrition(calories: number(dict["calories"], max: maxCalories),
                                      proteinG: number(dict["protein"], max: maxGrams),
                                      fatG: number(dict["fat"], max: maxGrams),
                                      carbsG: number(dict["carbs"], max: maxGrams))
            return NutritionItem(name: name, amount: amount, nutrition: nutrition)
        }
        return items.isEmpty ? nil : NutritionEstimate(items: Array(items.prefix(maxItems)))
    }

    static let maxCalories = 5_000.0
    static let maxGrams = 1_000.0
    static let maxItems = 30

    /// 数字 / 数字串("350 千卡"、"12.5g")→ Double;负数、认不出按 0。
    static func number(_ raw: Any?, max upper: Double = .greatestFiniteMagnitude) -> Double {
        let value: Double?
        switch raw {
        case let v as Double: value = v
        case let v as Int: value = Double(v)
        case let v as String:
            // 只认 ASCII 数字:`Character.isNumber` 会把「千」「万」也当成数字。
            let digits = v.prefix { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
            value = Double(digits)
        default: value = nil
        }
        guard let value, value.isFinite, value > 0, value <= upper else { return 0 }
        return value
    }
}

/// 饮食记录的汇总与喂给 AI 的摘要。
public enum FoodPlan {
    /// 某一天(本机日历)已估算的记录合计。
    public static func total(_ records: [(date: Date, nutrition: Nutrition)], on day: Date,
                             calendar: Calendar = .current) -> Nutrition {
        records.filter { calendar.isDate($0.date, inSameDayAs: day) }
            .reduce(.zero) { $0 + $1.nutrition }
    }

    /// 今天的营养合计 + 活动消耗,拼进饮食安排的输入(模型可见格式,中文)。
    /// **只给合计和条数,不给每顿饭的原文**(只把汇总发给 AI 的口径)。估算失败/还没估算的
    /// 那几条单独报个数——它们不等于没吃,合计只是"已估算部分"。什么都没有返回 nil。
    public static func todaySummary(estimatedCount: Int, pendingCount: Int, intake: Nutrition,
                                    activeEnergy: Double?) -> String? {
        var lines: [String] = []
        if estimatedCount > 0 {
            lines.append("今天已记录 \(estimatedCount) 次进食,估算摄入 \(Int(intake.calories.rounded())) 千卡(蛋白质 \(Int(intake.proteinG.rounded())) 克、脂肪 \(Int(intake.fatG.rounded())) 克、碳水 \(Int(intake.carbsG.rounded())) 克)")
        }
        if pendingCount > 0 {
            lines.append(estimatedCount > 0
                ? "另有 \(pendingCount) 次进食还没估算出热量,上面的合计不含它们"
                : "今天已记录 \(pendingCount) 次进食,但还没估算出热量")
        }
        if let activeEnergy, activeEnergy > 0 {
            lines.append("今天健康 App 记录的活动消耗 \(Int(activeEnergy.rounded())) 千卡(多来自 Apple Watch,不含静息消耗)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
