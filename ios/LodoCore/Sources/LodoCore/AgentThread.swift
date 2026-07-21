import Foundation
import SwiftData

/// AI 助手的一次对话;跨次启动持久保存(不像旧版 AgentView 那样关了就没)。
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求,
/// 与 TaskItem/MemoryItem 一致)。
@Model
public final class AgentThread {
    public var uuid: UUID = UUID()
    /// 首条用户消息截断生成;还没发过消息时为空,UI 显示"新对话"占位。
    public var title: String = ""
    public var createdAt: Date = Date.now
    /// 每次有新消息就更新;thread 列表按它倒序,"最近一次对话"也靠它判断。
    public var updatedAt: Date = Date.now

    public init() {
        self.uuid = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
