import Foundation
import SwiftData

/// 一位家人的健康档案(体检报告挂在谁名下)。
///
/// **本人没有这一行**:报告/条目上的 `profileUUID == nil` 就是本人。这样本人的档案
/// 不用先建、也删不掉,而"本人的数据参与 AI 健康分析、家人的不参与"这条硬约束
/// 只要判一个 nil,不会因为哪里多建了一行"我"而把家人的数据混进分析。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class HealthProfile {
    public var uuid: UUID = UUID()
    public var name: String = ""
    /// 和本人的关系,自由文本(爸爸/妈妈/孩子…),列表上显示在名字后面。
    public var relation: String = ""
    public var birthday: Date?
    public var notes: String = ""
    public var createdAt: Date = Date.now
    /// 经 CloudKit 共享时这台设备的身份(`SharedTripRole` 的存储值),空串 = 没共享。
    /// 同 `TravelTrip.shareRoleRaw`:**不进备份**,恢复出来就是不共享的一份。
    public var shareRoleRaw: String = ""
    /// 共享 zone 的 owner(`CKRecordZone.ID.ownerName`),成员取 share 时要用。
    public var shareZoneOwner: String = ""

    public init(uuid: UUID = UUID(), name: String, relation: String = "",
                birthday: Date? = nil, notes: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.name = name
        self.relation = relation
        self.birthday = birthday
        self.notes = notes
        self.createdAt = createdAt
    }

    public var shareRole: SharedTripRole? { SharedTripRole(rawValue: shareRoleRaw) }
    public var isShared: Bool { shareRole != nil }
}
