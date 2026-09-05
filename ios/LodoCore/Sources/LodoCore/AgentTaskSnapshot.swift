import Foundation

/// AI 助手对话里单条新建/修改的快照——提案阶段(AI 刚解析出来)和完成阶段
/// (实际保存的值,可能是用户点卡片进表单改过的)都用这一个结构体,序列化成
/// JSON 存进 AgentMessage,供聊天气泡渲染内联卡片。
public struct AgentTaskSnapshot: Codable, Equatable {
    /// nil = 新建,非 nil = 修改这个既有事项。
    public var existingUUID: UUID?
    /// 这条快照记录的"刚刚新建出来的那个事项"的 uuid。单条新建现在不再走确认卡片
    /// 而是直接落库(见 AgentHostView+Routing 的 route()),结果卡片上那颗 ✕ 要靠它
    /// 知道该撤销掉哪一条。修改结果恒为 nil(那种情况看 existingUUID)。
    /// Optional 属性缺键时解码成 nil,老库里没有这个字段的消息照常能读出来。
    public var createdUUID: UUID?
    /// 这条新建被用户在结果卡片上点掉了(事项已删除)。卡片是个开关:再点一下
    /// 按同一份 parsed 重新建一条(uuid 会是新的,届时连同这个标记一起写回)。
    /// 不是把 createdUUID 置 nil 来表示"已删除"——那样就和"老流程确认过的结果
    /// 卡片"分不开了,后者恒为 nil 且不该带开关。
    /// 声明成 Optional 是为了老库能解出来:合成的 Decodable 对**非** Optional
    /// 属性缺键时直接抛 keyNotFound,写了默认值也不管用(实测)。
    public var createdRemoved: Bool?
    public var parsed: ParsedTask

    public init(existingUUID: UUID?, parsed: ParsedTask, createdUUID: UUID? = nil,
                createdRemoved: Bool? = nil) {
        self.existingUUID = existingUUID
        self.parsed = parsed
        self.createdUUID = createdUUID
        self.createdRemoved = createdRemoved
    }

    /// 这条新建当前是否有效(卡片上蓝色对号 vs 灰色 ✕)。
    public var isCreatedActive: Bool { createdUUID != nil && createdRemoved != true }
}
