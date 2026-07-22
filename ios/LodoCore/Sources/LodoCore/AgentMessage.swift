import Foundation
import SwiftData

public enum AgentMessageRole: String {
    case user
    case assistant
}

/// 消息的展示形态;决定气泡怎么渲染,不影响已经落库的执行结果。
public enum AgentMessageKind: String {
    /// 纯文字:用户消息、批量确认执行后的结果回执、memorize 回执都走这个。
    case text
    /// 操作清单;按钮只在"当前 thread 最新一条"时可点,历史里的都是纯展示。
    case confirm
    /// 反问;候选不放气泡里,由输入栏上方的建议行展示(仅最新消息生效)。
    case clarify
    /// 记忆问答的回答,relatedTitles 附相关条目标题。
    case answer
    /// 批量操作执行完的回执;只在"当前 thread 最新一条"时气泡上带"撤销"按钮,
    /// 和 confirm 的按钮只在最新一条生效同一个道理。
    case executed
}

/// 对话里的一条消息。不建 SwiftData 关系,按 threadUUID 过滤查询即可
/// (与 MemoryChunk 按 itemUUID 过滤同一个风格)。
@Model
public final class AgentMessage {
    public var uuid: UUID = UUID()
    public var threadUUID: UUID = UUID()
    public var roleRaw: String = "user"
    public var kindRaw: String = "text"
    /// 展示文案:用户原话,或助手回答/反问问题/确认清单的可读描述。
    public var content: String = ""
    /// answer 消息的相关记忆条目标题;其余 kind 恒为空。
    public var relatedTitles: [String] = []
    /// clarify 消息的候选补充;由输入栏上方的建议行读取,不嵌进气泡里。
    public var clarifyOptions: [String] = []
    /// 这条消息带的附件,按顺序指向对应的 MemoryItem;没带附件为空数组。
    /// 每个附件既可能是发送前临时收藏的新内容,也可能是从记忆库里选的已有条目。
    public var attachmentMemoryUUIDs: [UUID] = []
    public var createdAt: Date = Date.now

    public init(
        threadUUID: UUID, role: AgentMessageRole, kind: AgentMessageKind = .text,
        content: String, relatedTitles: [String] = [], clarifyOptions: [String] = [],
        attachmentMemoryUUIDs: [UUID] = []
    ) {
        self.uuid = UUID()
        self.threadUUID = threadUUID
        self.roleRaw = role.rawValue
        self.kindRaw = kind.rawValue
        self.content = content
        self.relatedTitles = relatedTitles
        self.clarifyOptions = clarifyOptions
        self.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        self.createdAt = Date()
    }

    public var role: AgentMessageRole { AgentMessageRole(rawValue: roleRaw) ?? .user }
    public var kind: AgentMessageKind { AgentMessageKind(rawValue: kindRaw) ?? .text }
}
