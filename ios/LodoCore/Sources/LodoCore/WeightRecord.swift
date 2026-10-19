import Foundation
import SwiftData

/// 健康页「体重管理」里手记的一笔:体重和/或体脂率。
///
/// 独立轻量模型,不进记忆库(理由同 `PackingItem`:一天一笔、几年下来上千条,
/// 每条都成为记忆条目会把记忆库刷爆,单独一笔体重也不是值得收藏的资料)。
/// 健康库里的体重(HealthKit bodyMass)不落进这张表,只在显示/喂给 AI 时合并
/// (`WeightPlan.merge`),手记的同一天优先。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class WeightRecord {
    public var uuid: UUID = UUID()
    /// 称重那天(取时刻,显示和归日按本机日历)。
    public var date: Date = Date.now
    /// 公斤;nil = 这一笔只记了体脂率。
    public var weightKg: Double?
    /// 百分比(18.5 = 18.5%);nil = 没记。
    public var bodyFatPercent: Double?
    public var note: String = ""
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), date: Date = .now, weightKg: Double? = nil,
                bodyFatPercent: Double? = nil, note: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.note = note
        self.createdAt = createdAt
    }

    public var entry: WeightEntry {
        WeightEntry(id: uuid, date: date, weightKg: weightKg, bodyFatPercent: bodyFatPercent)
    }
}
