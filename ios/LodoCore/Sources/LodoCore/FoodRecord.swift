import Foundation
import SwiftData

/// 健康页「体重管理」里记的一顿饭:用户用文字描述吃了什么,AI 估算热量和三大营养素。
///
/// **先落库再估算**:用户写的原文(`text`)一提交就存下,估算结果回来再补上;
/// 估算失败也留着这一条(`estimated == false`),可以重试——"吃了什么"本身就是记录,
/// 不能因为网络不好就丢了。独立轻量模型,不进记忆库(理由同 `WeightRecord`)。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class FoodRecord {
    public var uuid: UUID = UUID()
    /// 吃的时间(默认提交那一刻)。
    public var date: Date = Date.now
    /// 用户写的原文,如「一碗牛肉面加个卤蛋」。
    public var text: String = ""
    /// AI 估算完成了没有。false 时下面几个数都是 0、不参与汇总。
    public var estimated: Bool = false
    public var calories: Double = 0
    public var proteinG: Double = 0
    public var fatG: Double = 0
    public var carbsG: Double = 0
    /// 逐项估算(`[NutritionItem]` 的 JSON),详情里列出来;空串 = 没有。
    public var itemsData: String = ""
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), date: Date = .now, text: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.date = date
        self.text = text
        self.createdAt = createdAt
    }

    public var items: [NutritionItem] {
        guard let data = itemsData.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([NutritionItem].self, from: data)) ?? []
    }

    /// 写入一次估算结果。
    public func apply(_ estimate: NutritionEstimate) {
        estimated = true
        calories = estimate.total.calories
        proteinG = estimate.total.proteinG
        fatG = estimate.total.fatG
        carbsG = estimate.total.carbsG
        itemsData = (try? JSONEncoder().encode(estimate.items))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var nutrition: Nutrition {
        estimated ? Nutrition(calories: calories, proteinG: proteinG, fatG: fatG, carbsG: carbsG) : .zero
    }
}
