import Foundation

/// AI 助手对话里单条新建/修改的快照——提案阶段(AI 刚解析出来)和完成阶段
/// (实际保存的值,可能是用户点卡片进表单改过的)都用这一个结构体,序列化成
/// JSON 存进 AgentMessage,供聊天气泡渲染内联卡片。
public struct AgentTaskSnapshot: Codable, Equatable {
    /// nil = 新建,非 nil = 修改这个既有事项。
    public var existingUUID: UUID?
    public var parsed: ParsedTask

    public init(existingUUID: UUID?, parsed: ParsedTask) {
        self.existingUUID = existingUUID
        self.parsed = parsed
    }
}
