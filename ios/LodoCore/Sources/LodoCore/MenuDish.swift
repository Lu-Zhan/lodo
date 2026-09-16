import Foundation
import SwiftData

/// 一张菜单上的一道菜。
///
/// 和资产/人脉/旅行**反过来**:那三类的成员本身就是记忆条目,菜品不是。
/// 理由是数量级——一张菜单动辄三五十道菜,每道都成为一条记忆条目会把记忆库
/// 刷屏、把向量索引撑满,而单独一道"炸鸡块"也不是用户想收藏的资料;真正值得
/// 留存和检索的是**整张菜单**(照片 + 原文 + 整理出来的菜品清单),所以菜单本身
/// 是打了保留标签「菜单」的 `MemoryItem`(见 `MemoryItem.menuSourceLanguage`
/// 那组字段),菜品是这个轻量模型,靠 `menuUUID` 关联、**不建 SwiftData 关系**
/// (理由同 `ContactRelationship`/`TravelTrip`:关系在 CloudKit 同步下更容易出岔子)。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class MenuDish {
    public var uuid: UUID = UUID()
    /// 属于哪张菜单(那条 `MemoryItem` 的 uuid)。
    public var menuUUID: UUID = UUID()
    /// 菜单上照抄下来的原文名称(可能是外文)。
    public var originalName: String = ""
    /// 翻译成应用内语言后的名称;菜单本来就是这个语言时与原名相同。
    public var translatedName: String = ""
    /// AI 给的一句话介绍(主要食材/做法/口味)。菜单没写内容、或名字看不懂时
    /// 由 AI 按常识补全。
    public var intro: String = ""
    /// 分类(前菜/主菜/甜点/饮品…)。菜单上有就用它的,没有由 AI 归类;
    /// 归不出来时为空串,列表里收进"其他"。
    public var category: String = ""
    /// 价格数字本身,不含币种符号(币种记在菜单那条 `MemoryItem` 上,
    /// 一张菜单一个币种,不逐道菜存)。菜单没标价时为 nil。
    public var price: Double?
    /// 在菜单里的顺序(AI 返回的顺序),分组后组内按它排。
    public var sortIndex: Int = 0
    /// 点菜时勾上的。持久化而不是只放在视图状态里——点菜过程会切出去查东西、
    /// 会隔一会儿再回来,选了一半的菜不该因为退出页面就没了。
    public var selected: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), menuUUID: UUID, originalName: String,
                translatedName: String = "", intro: String = "", category: String = "",
                price: Double? = nil, sortIndex: Int = 0, selected: Bool = false,
                createdAt: Date = .now) {
        self.uuid = uuid
        self.menuUUID = menuUUID
        self.originalName = originalName
        self.translatedName = translatedName
        self.intro = intro
        self.category = category
        self.price = price
        self.sortIndex = sortIndex
        self.selected = selected
        self.createdAt = createdAt
    }
}
