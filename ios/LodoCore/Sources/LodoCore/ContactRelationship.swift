import Foundation
import SwiftData

/// 两个"人脉"条目(MemoryItem,tags 含 contactTagName)之间的一条关系边:
/// 无向、单条 label(A-B 之间只存一条,不区分谁是发起方),两边详情页共用同一份
/// 展示。用 UUID 互相引用而不是 SwiftData `@Relationship`,和仓库里其余多值/
/// 跨记录引用(tags、聊天附件的 attachmentMemoryUUIDs)的一贯写法保持一致。
@Model
public final class ContactRelationship {
    public var uuid: UUID = UUID()
    public var memoryUUIDA: UUID = UUID()
    public var memoryUUIDB: UUID = UUID()
    /// 关系描述,如"同事""大学同学"。
    public var label: String = ""
    public var createdAt: Date = Date.now

    public init(memoryUUIDA: UUID, memoryUUIDB: UUID, label: String) {
        self.uuid = UUID()
        self.memoryUUIDA = memoryUUIDA
        self.memoryUUIDB = memoryUUIDB
        self.label = label
        self.createdAt = Date()
    }

    public func involves(_ uuid: UUID) -> Bool {
        memoryUUIDA == uuid || memoryUUIDB == uuid
    }

    /// 边的另一端;传入的 uuid 不在这条边上时返回 nil。
    public func other(than uuid: UUID) -> UUID? {
        if memoryUUIDA == uuid { return memoryUUIDB }
        if memoryUUIDB == uuid { return memoryUUIDA }
        return nil
    }
}
