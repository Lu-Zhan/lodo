import Foundation
import SwiftData

/// 用户主动创建的记忆标签。标签全集 = 本表 ∪ 各条目 tags 里出现过的标签;
/// AI 自动打的标签不落本表,只有用户显式创建的才有条目——这样删除条目后
/// 它带来的标签自然消失,而用户创建的空标签能保留。
/// 与 TaskItem/MemoryItem 一样:属性全给默认值、无 unique(CloudKit 硬性要求),
/// 名字唯一性由应用层保证。
@Model
public final class MemoryTag {
    public var name: String = ""
    public var createdAt: Date = Date.now

    public init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}
