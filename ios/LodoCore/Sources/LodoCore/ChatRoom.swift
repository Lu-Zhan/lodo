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
    /// 免打扰:收到新消息不发通知(本机偏好,不进共享)。
    public var muted: Bool = false

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
    /// 分享进来的 app 内容(旅行、资产…),`cardData` 存 `ChatCard`。
    case card
}

/// 聊天里分享的一张内容卡片。`body` 是分享那一刻整理好的内容快照(和 AI 对话里「引用」
/// 同一份文字,见 `AgentReferenceRenderer`):收到的人没有这份内容时能看,AI 处理
/// 聊天上下文时也直接读它。`shareURL` 只在这份内容本身已经经 CloudKit 共享时才有
/// (共享旅行、共享资产台账),收到的人点「加入共享」就是接受那份共享的邀请。
public struct ChatCard: Codable, Equatable, Sendable {
    public var reference: AgentReference
    public var body: String
    public var shareURL: String?

    public init(reference: AgentReference, body: String, shareURL: String? = nil) {
        self.reference = reference
        self.body = body
        self.shareURL = shareURL
    }

    /// 卡片上露的几行摘要(完整内容点「查看内容」看)。
    public func preview(maxLines: Int = 3) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        return lines.count > maxLines ? head + "\n…" : head
    }

    /// 消息的 `content`(列表预览、AI 上下文的那一行):「旅行:北海道」。
    public var summaryLine: String {
        reference.kind.promptLabel + ":" + reference.title
    }

    public static func decode(_ data: Data?) -> ChatCard? {
        data.flatMap { try? JSONDecoder().decode(ChatCard.self, from: $0) }
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }
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
    /// `card` 消息的内容卡片(JSON 编码的 `ChatCard`);其余 kind 为 nil。
    public var cardData: Data? = nil
    /// `ai` 消息附带的提案(JSON 编码的 `ChatProposal`):AI 在群聊里不直接写任何东西,
    /// 结论变成卡片,成员各自确认后才写进自己的(或共享的)lodo。
    public var proposalData: Data? = nil

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
    public var card: ChatCard? { ChatCard.decode(cardData) }
    public var proposal: ChatProposal? { ChatProposal.decode(proposalData) }
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
        if let card = message.cardData { f["card"] = .data(card) }
        if let proposal = message.proposalData { f["proposal"] = .data(proposal) }
        return SharedRecordSnapshot(type: .chatMessage, uuid: message.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to message: ChatRoomMessage) {
        message.kindRaw = f.string("kindRaw") ?? ChatMessageKind.text.rawValue
        message.content = f.string("content") ?? ""
        message.createdAt = f.date("createdAt") ?? message.createdAt
        message.senderHint = f.string("senderHint") ?? ""
        message.cardData = f.data("card")
        message.proposalData = f.data("proposal")
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

// MARK: - 群聊里的 AI

/// AI 在群聊里给出的、要成员确认才写入的东西。几种可以同时有(「定了:规划这样排,
/// 我负责订酒店」= 一份规划 + 一条任务)。
public struct ChatProposal: Codable, Equatable {
    /// 规划/整理出来的行程。成员点「写入行程」走 `TravelStore.applyPlan`:按旅行名
    /// 完全一致写进已有的那趟(共享旅行就随之同步给所有人),否则新建。
    public var tripPlan: TripPlanProposal?
    /// 调整一趟已经记下的(共享)旅行。id 是共享旅行里行程项的 uuid,各成员一致。
    public var tripEdit: TripEdit?
    /// 给叫 AI 的那位成员建的任务(「我负责订酒店」);谁点谁的 lodo 里加。
    public var tasks: [ParsedTask]
    public var countdowns: [CountdownDraft]

    public init(tripPlan: TripPlanProposal? = nil, tripEdit: TripEdit? = nil,
                tasks: [ParsedTask] = [], countdowns: [CountdownDraft] = []) {
        self.tripPlan = tripPlan
        self.tripEdit = tripEdit
        self.tasks = tasks
        self.countdowns = countdowns
    }

    public var isEmpty: Bool {
        tripPlan == nil && tripEdit == nil && tasks.isEmpty && countdowns.isEmpty
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> ChatProposal? {
        data.flatMap { try? JSONDecoder().decode(ChatProposal.self, from: $0) }
    }
}

/// 把房间里的消息拼成发给模型的「聊天记录」。
public enum ChatTranscript {
    public struct Entry: Sendable {
        public var sender: String
        public var isMe: Bool
        public var kind: ChatMessageKind
        public var content: String
        public var cardBody: String?
        public var createdAt: Date

        public init(sender: String, isMe: Bool, kind: ChatMessageKind, content: String,
                    cardBody: String? = nil, createdAt: Date) {
            self.sender = sender
            self.isMe = isMe
            self.kind = kind
            self.content = content
            self.cardBody = cardBody
            self.createdAt = createdAt
        }
    }

    /// 只取最近的:条数和总字数都封顶,超了从最早的开始丢(最近说的最要紧)。
    /// 卡片快照单独截断,一张长行程不该挤掉整段讨论。
    public static func build(_ entries: [Entry], maxMessages: Int = 40, maxChars: Int = 12_000,
                             cardBodyLimit: Int = 1_500, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        var lines: [String] = []
        var total = 0
        for entry in entries.suffix(maxMessages).reversed() {
            let line = format(entry, time: formatter.string(from: entry.createdAt), cardBodyLimit: cardBodyLimit)
            if total + line.count > maxChars, !lines.isEmpty { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    private static func format(_ entry: Entry, time: String, cardBodyLimit: Int) -> String {
        let who = entry.isMe ? "我" : entry.sender
        switch entry.kind {
        case .system:
            return "[\(time)] (系统)\(entry.content)"
        case .ai:
            return "[\(time)] \(who)的 AI:\(entry.content)"
        case .card:
            var line = "[\(time)] \(who) 分享了「\(entry.content)」"
            if let body = entry.cardBody?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                let clipped = body.count > cardBodyLimit ? String(body.prefix(cardBodyLimit)) + "…" : body
                line += ":\n" + clipped
            }
            return line
        case .text:
            return "[\(time)] \(who):\(entry.content)"
        }
    }
}

/// 群聊模式的 prompt 段,拼在 command 的 system prompt 末尾(`groupChat:`)。
/// 喂给模型的格式,不随应用语言变。
public enum GroupChatPrompt {
    /// requester:叫 AI 的那位成员的名字(取不到时为空)。
    public static func block(roomTitle: String, requester: String = "") -> String {
        let who = requester.isEmpty ? "叫你的这位成员" : "「\(requester)」"
        return """
        群聊模式:你在一个多人共享聊天室「\(roomTitle)」里,被其中一位成员叫来帮忙,\
        用户消息里的「聊天记录」是房间里最近的对话(每行写明是谁说的,「我」= \(who);\
        「分享了」后面是成员分享进来的内容当时的样子)。
        1. 你的回复会发给房间里**所有人**看:用大家都能看懂的口吻,提到某个人就用他的名字;\
        回复里**不要**用「我」指代叫你的那位成员(大家看到的「我」会以为是你自己),\
        说到他时写\(requester.isEmpty ? "「你」" : "他的名字或「你」")。
        2. 以大家讨论**敲定**的结论为准;还在争的地方列出几种意见、给建议,不要替大家拍板。
        3. 这一轮没有给你叫你那位成员的私人数据(任务、记忆、资产、健康、偏好),也不要编造或打听。
        4. 能用的动作只有:answer(回话)、plan_trip(把讨论出来的行程整理成一份规划)、\
        edit_trip(调整已经共享的旅行,必须先 read_trip 拿到 id)、create(给「我」新建任务)、\
        create_countdown。其他动作在群聊里都不可用,需要时用 answer 说明请成员到自己的 AI 助手里处理。
        6. 「我」在聊天里认领的分工(「订酒店我来负责」「机票我来买」)**一定**单独给一条 create,\
        标题写要做的事,时间按聊天里说的,没说就定在出发前几天;不要只写进行程的备注里。\
        别人认领的事不给「我」建任务。
        5. 写操作都**不会直接执行**:会变成聊天里的一张卡片,成员确认后才写入。\
        所以大家已经说定的事可以直接给出 plan_trip / edit_trip,不必再反问确认;\
        同时给一句 answer 说明你整理了什么。
        """
    }
}

// MARK: - 新消息提醒

public enum ChatNotificationPlan {
    /// 只提醒这么久以内发出的消息:刚加入房间、或者离线很久后一次拉下来的历史消息
    /// 不该一条条弹出来。
    public static let freshWindow: TimeInterval = 10 * 60

    public static func shouldNotify(fromMe: Bool, createdAt: Date, now: Date,
                                    muted: Bool, viewingRoom: Bool) -> Bool {
        !fromMe && !muted && !viewingRoom && now.timeIntervalSince(createdAt) <= freshWindow
    }

    /// 通知正文的一行。界面语言的那部分(「分享了」「的 AI」)由调用方传进来已经翻好的格式。
    public static func line(sender: String, kind: ChatMessageKind, content: String) -> String {
        switch kind {
        case .system: return content
        default: return sender.isEmpty ? content : sender + ": " + content
        }
    }

    /// 一个房间这一批里有几条新消息:只发一条通知,正文是最新那条,多条时注明一共几条。
    public static func body(lines: [String], moreFormat: (Int) -> String) -> String? {
        guard let last = lines.last else { return nil }
        return lines.count > 1 ? last + "\n" + moreFormat(lines.count) : last
    }
}
