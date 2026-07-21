import Foundation
import SwiftData

/// MemoryItem 内容的分片 + 向量,供语义检索用。不建 SwiftData 关系,
/// 按 itemUUID 过滤查询即可(与 TaskAttachment 一样"值拷贝、不建关系"的风格)。
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求,
/// 与 TaskItem/MemoryItem 一致)。embedding 为空数组表示还没算出向量
/// (端上/云端 embedding 都不可用时的退化状态,此时只参与关键词检索)。
@Model
public final class MemoryChunk {
    public var uuid: UUID = UUID()
    public var itemUUID: UUID = UUID()
    public var text: String = ""
    public var embedding: [Float] = []
    public var createdAt: Date = Date.now

    public init(itemUUID: UUID, text: String, embedding: [Float] = []) {
        self.uuid = UUID()
        self.itemUUID = itemUUID
        self.text = text
        self.embedding = embedding
        self.createdAt = Date()
    }
}
