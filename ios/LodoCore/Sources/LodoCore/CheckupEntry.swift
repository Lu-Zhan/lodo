import Foundation
import SwiftData

/// 体检报告里整理出来的一个条目:一项指标/检查项,或者整份报告的综合建议。
///
/// 和菜单同一个分层:**整份报告**是打了保留标签「体检报告」的 `MemoryItem`(原文件
/// 当附件、整理结果 + OCR 原文进 `sourceText`,记忆搜索和"问 AI"能命中),条目是
/// 这个轻量模型,靠 `reportUUID` 关联、不建 SwiftData 关系(理由同 `MenuDish`:
/// 一份报告上百项,每项都成记忆条目会把记忆库和向量索引刷爆)。
///
/// `profileUUID` 和 `date` 是从报告上**冗余**下来的:时间轴按指标看要跨报告取同一
/// 个人的全部记录,每次都回查报告太绕;改报告的日期/归属时由 `CheckupStore` 一起改。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class CheckupEntry {
    public var uuid: UUID = UUID()
    /// 属于哪份报告(那条 `MemoryItem` 的 uuid)。
    public var reportUUID: UUID = UUID()
    /// 属于谁:nil = 本人,否则是 `HealthProfile.uuid`。
    public var profileUUID: UUID?
    /// `CheckupEntryKind` 的存储值(item/advice),**别改**。
    public var kindRaw: String = CheckupEntryKind.item.rawValue
    /// 所属项目/科室(血常规/肝功能/B 超…),报告上怎么分就怎么分。
    public var category: String = ""
    /// 指标/检查项名称;综合建议条目为空串。
    public var name: String = ""
    /// 结果原样(5.6 / 阴性 / 未见异常),数值从这里解析(`CheckupPlan.numericValue`)。
    public var value: String = ""
    public var unit: String = ""
    /// 参考范围原样(3.9-6.1 / <5.2)。
    public var referenceRange: String = ""
    /// `CheckupFlag` 的存储值(high/low/abnormal/normal),空串 = 报告上没标。**别改**。
    public var flagRaw: String = ""
    /// 文字结论/描述(影像、体格检查这类没有数值的项写在这里)。
    public var conclusion: String = ""
    /// 报告里针对这一项的分析/建议;综合建议条目的正文也在这里。
    public var advice: String = ""
    /// 报告日期(体检那天)。
    public var date: Date = Date.now
    /// 在报告里的顺序(AI 返回的顺序),分组后组内按它排。
    public var sortIndex: Int = 0
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), reportUUID: UUID, profileUUID: UUID? = nil,
                kind: CheckupEntryKind = .item, category: String = "", name: String = "",
                value: String = "", unit: String = "", referenceRange: String = "",
                flag: CheckupFlag? = nil, conclusion: String = "", advice: String = "",
                date: Date, sortIndex: Int = 0, createdAt: Date = .now) {
        self.uuid = uuid
        self.reportUUID = reportUUID
        self.profileUUID = profileUUID
        self.kindRaw = kind.rawValue
        self.category = category
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.flagRaw = flag?.rawValue ?? ""
        self.conclusion = conclusion
        self.advice = advice
        self.date = date
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    public var kind: CheckupEntryKind { CheckupEntryKind(rawValue: kindRaw) ?? .item }
    public var flag: CheckupFlag? { CheckupFlag(rawValue: flagRaw) }
}
