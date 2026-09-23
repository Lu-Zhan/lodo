import Foundation

/// AI 助手右侧栏里展示的内容。对话里产出的"页面"——先只有旅行两种,
/// 以后记忆/菜单/待办按同一个入口往里加。
///
/// 解析是纯函数(给消息,不查库),`AgentInspectorTargetTests` 离线单测。
public enum AgentInspectorTarget: Hashable, Sendable {
    /// 已经落库的一次旅行 → 旅行详情页(可编辑,和旅行页那张同一个视图)。
    case trip(UUID)
    /// 还没写入(或写入后又撤销)的规划卡片,值是那条消息的 uuid → 只读预览。
    case tripPlan(UUID)

    /// 单条消息对应的右栏内容。规划已写入时直接指向那次旅行——写进去之后
    /// 右栏该看的是真实数据(之后的 edit_trip 改的也是它),不是当时那份提案。
    /// 已撤销的调整不给:它改的那几项已经回滚,点过去看到的和卡片上写的对不上。
    public static func from(_ message: AgentMessage) -> AgentInspectorTarget? {
        switch message.kind {
        case .tripPlan:
            guard let data = message.tripPlanSnapshotData,
                  let plan = try? JSONDecoder().decode(TripPlanProposal.self, from: data)
            else { return nil }
            if plan.isApplied, let trip = plan.appliedTripUUID { return .trip(trip) }
            return .tripPlan(message.uuid)
        case .tripEdit:
            guard let data = message.tripEditSnapshotData,
                  let record = try? JSONDecoder().decode(TripEditRecord.self, from: data)
            else { return nil }
            return .trip(record.tripUUID)
        default:
            return nil
        }
    }

    /// 一个对话里"最新那份"可展示内容:从后往前找第一条能对应上的消息。
    /// 已撤销的调整跳过,继续往前找(那次旅行本身可能还由更早的规划指着)。
    public static func latest(in messages: [AgentMessage]) -> AgentInspectorTarget? {
        for message in messages.reversed() {
            if message.kind == .tripEdit,
               let data = message.tripEditSnapshotData,
               let record = try? JSONDecoder().decode(TripEditRecord.self, from: data),
               record.reverted == true {
                continue
            }
            if let target = from(message) { return target }
        }
        return nil
    }
}
