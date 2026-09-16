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
    /// 待回答的反问;askSnapshotData 存题目,气泡渲染成可交互的询问卡
    /// (可翻页、单选/多选、带推荐项),按钮只在"当前 thread 最新一条"时可点。
    case ask
    /// 反问已作答的只读记录卡;askSnapshotData 里 answers 与 questions 等长。
    case askResult
    /// 记忆问答的回答,relatedTitles 附相关条目标题。
    case answer
    /// 批量操作执行完的回执;只在"当前 thread 最新一条"时气泡上带"撤销"按钮,
    /// 和 confirm 的按钮只在最新一条生效同一个道理。
    case executed
    /// AI 主动建议收藏(用户没明确要求);只在"当前 thread 最新一条"时气泡上带
    /// "收藏这条"按钮,和 confirm/executed 同一个道理。
    case memorizeSuggestion
    /// 单条新建/修改的待确认提案;卡片 + Cancel/Confirm,按钮只在"当前 thread
    /// 最新一条"时可点,和 confirm/executed 同一个道理。taskSnapshotData 存
    /// AI 解析出的字段。
    case taskProposal
    /// 单条新建/修改确认后的最终态,只读卡片,不带按钮;taskSnapshotData 存
    /// 实际保存的字段(可能是用户点卡片进表单改过的,不一定等于提案阶段的值)。
    case taskResult
    /// 收藏(memorize/suggestMemorize 确认后)完成态,只读卡片;
    /// resultMemoryUUID 指向对应的 MemoryItem。
    case memoryResult
    /// AI 自动规划的行程(plan_trip);tripPlanSnapshotData 存规划内容与写入状态。
    /// 「写入行程」只在"当前 thread 最新一条"时可点(被后面修改过的旧规划不该
    /// 再写进去);写入之后的撤销/重新写入不限最新一条——它动的就是卡片上
    /// 记着的那几条,不依赖当前上下文(同新建待办结果卡片那颗开关)。
    case tripPlan
    /// AI 调整已记下行程(edit_trip)的执行结果;tripEditSnapshotData 存改动记录。
    /// 已经落库,卡片上的撤销不限最新一条(动的是记录里那几项)。
    case tripEdit
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
    /// ask/askResult 消息的题目与答案(JSON 编码的 AgentAskSnapshot);
    /// 其余 kind 恒为 nil。
    public var askSnapshotData: Data? = nil
    /// 这条消息带的附件,按顺序指向对应的 MemoryItem;没带附件为空数组。
    /// 每个附件既可能是发送前临时收藏的新内容,也可能是从记忆库里选的已有条目。
    public var attachmentMemoryUUIDs: [UUID] = []
    /// taskProposal/taskResult 消息的字段快照(JSON 编码的 AgentTaskSnapshot);
    /// 其余 kind 恒为 nil。
    public var taskSnapshotData: Data? = nil
    /// memoryResult 消息指向的 MemoryItem;其余 kind 恒为 nil。
    public var resultMemoryUUID: UUID? = nil
    /// 发送这条消息时用户引用的另一条消息的文本快照;没有引用为 nil。存快照而不是
    /// UUID 引用——"修改"会删除历史消息,UUID 引用可能悬空,快照更稳。
    public var quotedContent: String? = nil
    /// tripPlan 消息的规划快照(JSON 编码的 TripPlanProposal);其余 kind 恒为 nil。
    public var tripPlanSnapshotData: Data? = nil
    /// tripEdit 消息的改动记录(JSON 编码的 TripEditRecord);其余 kind 恒为 nil。
    public var tripEditSnapshotData: Data? = nil
    public var createdAt: Date = Date.now

    public init(
        threadUUID: UUID, role: AgentMessageRole, kind: AgentMessageKind = .text,
        content: String, relatedTitles: [String] = [], askSnapshotData: Data? = nil,
        attachmentMemoryUUIDs: [UUID] = [], taskSnapshotData: Data? = nil,
        resultMemoryUUID: UUID? = nil, quotedContent: String? = nil,
        tripPlanSnapshotData: Data? = nil, tripEditSnapshotData: Data? = nil
    ) {
        self.uuid = UUID()
        self.threadUUID = threadUUID
        self.roleRaw = role.rawValue
        self.kindRaw = kind.rawValue
        self.content = content
        self.relatedTitles = relatedTitles
        self.askSnapshotData = askSnapshotData
        self.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        self.taskSnapshotData = taskSnapshotData
        self.resultMemoryUUID = resultMemoryUUID
        self.quotedContent = quotedContent
        self.tripPlanSnapshotData = tripPlanSnapshotData
        self.tripEditSnapshotData = tripEditSnapshotData
        self.createdAt = Date()
    }

    public var role: AgentMessageRole { AgentMessageRole(rawValue: roleRaw) ?? .user }
    public var kind: AgentMessageKind { AgentMessageKind(rawValue: kindRaw) ?? .text }
}
