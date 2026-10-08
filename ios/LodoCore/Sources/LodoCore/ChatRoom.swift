import Foundation
import SwiftData

/// 共享聊天室(仅 iOS/macOS;2026-10)。和「我的 AI 助手」那条单一持续对话(`AgentMessage`)
/// 完全分开:一个聊天室是一个 CloudKit 共享 zone(`chat-<uuid>`),成员经 CKShare 加入,
/// 同步走 `SharedTripSync` 那一对引擎(见 `SharedChatMapping`)。
///
/// 可以有很多个;**只有创建者能销毁**(删掉服务器上的 zone,所有成员本地的这个房间和
/// 全部消息随之删除,不留副本),成员只能退出(同样删掉自己本地这一份)。
///
/// 和其他模型一样,每个属性有默认值、没有 unique 约束——SwiftData 私有库镜像的要求;
/// 同一个 uuid 出现多行(自己的另一台设备经私有库镜像 + 共享库各落一行)由同步层去重。
@Model
public final class ChatRoom {
    public var uuid: UUID = UUID()
    public var title: String = ""
    public var createdAt: Date = Date.now
    /// 这台设备在房间里的身份,同 `TravelTrip.shareRoleRaw`:`owner` / `participant`,
    /// 空串 = 还没建好共享 zone(刚创建、iCloud 不可用时)。
    public var shareRoleRaw: String = ""
    /// zone 的 owner(`CKRecordZone.ID.ownerName`)。
    public var shareZoneOwner: String = ""
    /// 最近一条消息的时间(列表排序、未读判断用;收到/发出消息时更新)。
    public var lastMessageAt: Date = Date.now
    /// 自己读到哪儿了(本机偏好,经私有库镜像到自己的其他设备,不进共享)。
    public var lastReadAt: Date = Date.distantPast
    /// 输入栏左边那颗「AI」开关(每人各自的,不进共享;开着时这台设备用自己配置的
    /// AI 服务商处理聊天上下文)。
    public var aiEnabled: Bool = false

    public init(uuid: UUID = UUID(), title: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.title = title
        self.createdAt = createdAt
        self.lastMessageAt = createdAt
    }

    public var shareRole: SharedTripRole? { SharedTripRole(rawValue: shareRoleRaw) }
    public var isOwner: Bool { shareRole != .participant }
}

/// 消息的种类。**存储值别改**(进 CloudKit 记录的 payload)。
public enum ChatMessageKind: String, Codable, Sendable {
    /// 成员发的文字。
    case text
    /// 某位成员的 AI 回复(谁的设备调的 AI,`senderName` 就写谁)。
    case ai
    /// 系统提示(「X 创建了聊天室」这类),不归属某个人。
    case system
}

/// 聊天室里的一条消息。**只追加、不修改**——没有两边同时改同一条的问题,
/// 所以不需要旅行那套字段级三方合并。
@Model
public final class ChatRoomMessage {
    public var uuid: UUID = UUID()
    public var roomUUID: UUID = UUID()
    public var kindRaw: String = ChatMessageKind.text.rawValue
    public var content: String = ""
    /// 发送者的显示名。自己发的留空(界面上显示在右侧);别人发的由收到的一端
    /// 按 CloudKit 记录的创建者查共享成员名(查不到时退回消息里带的 `senderHint`)。
    public var senderName: String = ""
    /// 发送者写进 payload 的名字(自己发的就是自己的名字)。成员表取不到时兜底显示,
    /// 原样留着也让这条的本地快照和服务器那份一致。
    public var senderHint: String = ""
    /// 这条是不是自己(这个 iCloud 账号)发的。按记录创建者判断,不进 payload。
    public var fromMe: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), roomUUID: UUID, kind: ChatMessageKind = .text,
                content: String, senderName: String = "", senderHint: String = "",
                fromMe: Bool = false, createdAt: Date = .now) {
        self.uuid = uuid
        self.roomUUID = roomUUID
        self.kindRaw = kind.rawValue
        self.content = content
        self.senderName = senderName
        self.senderHint = senderHint
        self.fromMe = fromMe
        self.createdAt = createdAt
    }

    public var kind: ChatMessageKind { ChatMessageKind(rawValue: kindRaw) ?? .text }
}

// MARK: - 同步映射

/// 聊天室 ↔ 共享记录。zone 名 `chat-<房间 uuid>`,记录类型 `ChatRoom` / `ChatMessage`。
public enum SharedChatMapping {
    public static let zonePrefix = "chat-"

    public static func zoneName(for roomUUID: UUID) -> String {
        zonePrefix + roomUUID.uuidString
    }

    public static func roomUUID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count)))
    }

    /// 房间本身只同步名字和创建时间;身份、已读、AI 开关都是每台设备/每个人自己的。
    public static func snapshot(of room: ChatRoom) -> SharedRecordSnapshot {
        var f = SharedFields()
        f["title"] = .string(room.title)
        f["createdAt"] = .date(room.createdAt)
        return SharedRecordSnapshot(type: .chatRoom, uuid: room.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to room: ChatRoom) {
        room.title = f.string("title") ?? room.title
        room.createdAt = f.date("createdAt") ?? room.createdAt
    }

    /// `senderHint` 是发送者自己写进去的名字,成员表还没取到时兜底显示。
    public static func snapshot(of message: ChatRoomMessage) -> SharedRecordSnapshot {
        var f = SharedFields()
        f["kindRaw"] = .string(message.kindRaw)
        f["content"] = .string(message.content)
        f["createdAt"] = .date(message.createdAt)
        if !message.senderHint.isEmpty { f["senderHint"] = .string(message.senderHint) }
        return SharedRecordSnapshot(type: .chatMessage, uuid: message.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to message: ChatRoomMessage) {
        message.kindRaw = f.string("kindRaw") ?? ChatMessageKind.text.rawValue
        message.content = f.string("content") ?? ""
        message.createdAt = f.date("createdAt") ?? message.createdAt
        message.senderHint = f.string("senderHint") ?? ""
    }

    public static func senderHint(_ f: SharedFields) -> String? {
        f.string("senderHint")
    }
}

/// 本地 → 服务器。和旅行的 `SharedTripPlanner.pushPlan` 不同的两点:
/// - **只推自己发的消息**:别人的消息落到本地后,快照里少了服务器那份才有的东西
///   (或者经私有库镜像先到、账本里还没有),按通用对账会被当成"本地改了"再推回去,
///   等于替别人重写一遍他的消息。
/// - **消息永不经对账删除**:消息只追加,本地少一条(去重、刚退出)不代表要删服务器上的;
///   整个房间的去留走 zone 的删除。
public enum SharedChatPlanner {
    public static func pushPlan(room: SharedRecordSnapshot?, myMessages: [SharedRecordSnapshot],
                                ledger: [UUID: SharedLedgerRecord]) -> SharedPushPlan {
        var plan = SharedPushPlan()
        let candidates = (room.map { [$0] } ?? []) + myMessages
        for snapshot in candidates where ledger[snapshot.uuid]?.fields != snapshot.fields {
            plan.saves.append(snapshot.uuid)
        }
        plan.saves.sort { $0.uuidString < $1.uuidString }
        return plan
    }
}

/// 列表/未读这类纯计算。
public enum ChatRoomPlan {
    /// 别人发的、晚于已读位置的消息条数。
    public static func unreadCount(_ messages: [(createdAt: Date, fromMe: Bool)],
                                   lastReadAt: Date) -> Int {
        messages.filter { !$0.fromMe && $0.createdAt > lastReadAt }.count
    }

    /// 新建房间时的默认名字:「聊天室」,已有同名的往后编号(「聊天室 2」)。
    public static func defaultTitle(base: String, existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
