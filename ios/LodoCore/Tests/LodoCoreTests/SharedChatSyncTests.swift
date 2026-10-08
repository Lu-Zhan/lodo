import XCTest
@testable import LodoCore

final class SharedChatSyncTests: XCTestCase {
    func testZoneNameRoundTripAndKind() {
        let id = UUID()
        let name = SharedChatMapping.zoneName(for: id)
        XCTAssertEqual(name, "chat-" + id.uuidString)
        XCTAssertEqual(SharedChatMapping.roomUUID(fromZoneName: name), id)
        XCTAssertEqual(SharedZoneKind(zoneName: name), .chat)
        XCTAssertEqual(SharedZoneKind.containerUUID(fromZoneName: name), id)
        XCTAssertNil(SharedChatMapping.roomUUID(fromZoneName: SharedTripMapping.zoneName(for: id)))
    }

    /// 记录类型是 CloudKit schema 里的名字,别改。
    func testRecordTypeNamesAreStable() {
        XCTAssertEqual(SharedRecordType.chatRoom.rawValue, "ChatRoom")
        XCTAssertEqual(SharedRecordType.chatMessage.rawValue, "ChatMessage")
        XCTAssertEqual(ChatMessageKind.text.rawValue, "text")
        XCTAssertEqual(ChatMessageKind.ai.rawValue, "ai")
        XCTAssertEqual(ChatMessageKind.system.rawValue, "system")
    }

    /// 房间只同步名字和创建时间;身份、已读、AI 开关是每个人自己的。
    func testRoomSnapshotOnlyCarriesSharedFields() {
        let room = ChatRoom(title: "京都五人行", createdAt: Date(timeIntervalSince1970: 1000))
        room.aiEnabled = true
        room.lastReadAt = Date(timeIntervalSince1970: 2000)
        room.shareRoleRaw = "owner"
        let snapshot = SharedChatMapping.snapshot(of: room)
        XCTAssertEqual(snapshot.type, .chatRoom)
        XCTAssertEqual(Set(snapshot.fields.keys), ["title", "createdAt"])

        let other = ChatRoom()
        SharedChatMapping.apply(snapshot.fields, to: other)
        XCTAssertEqual(other.title, "京都五人行")
        XCTAssertEqual(other.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertFalse(other.aiEnabled)
    }

    func testMessageSnapshotRoundTrip() {
        let roomID = UUID()
        let message = ChatRoomMessage(roomUUID: roomID, kind: .ai, content: "第二天去奈良",
                                      senderHint: "小王", fromMe: true,
                                      createdAt: Date(timeIntervalSince1970: 5))
        let snapshot = SharedChatMapping.snapshot(of: message)
        XCTAssertEqual(snapshot.type, .chatMessage)
        XCTAssertNil(snapshot.fields["fromMe"])
        XCTAssertEqual(SharedChatMapping.senderHint(snapshot.fields), "小王")

        let copy = ChatRoomMessage(roomUUID: roomID, content: "")
        SharedChatMapping.apply(snapshot.fields, to: copy)
        XCTAssertEqual(copy.kind, .ai)
        XCTAssertEqual(copy.content, "第二天去奈良")
        XCTAssertEqual(copy.createdAt, Date(timeIntervalSince1970: 5))
        XCTAssertFalse(copy.fromMe)
        XCTAssertEqual(copy.senderHint, "小王")
        // 收到的消息落地后快照和服务器那份一致,不会被当成本地改动。
        XCTAssertEqual(SharedChatMapping.snapshot(of: copy).fields, snapshot.fields)

        message.senderHint = ""
        XCTAssertNil(SharedChatMapping.senderHint(SharedChatMapping.snapshot(of: message).fields))
    }

    func testUnreadCountIgnoresOwnAndOldMessages() {
        let read = Date(timeIntervalSince1970: 100)
        let messages: [(createdAt: Date, fromMe: Bool)] = [
            (Date(timeIntervalSince1970: 50), false),
            (Date(timeIntervalSince1970: 150), true),
            (Date(timeIntervalSince1970: 160), false),
            (Date(timeIntervalSince1970: 170), false),
        ]
        XCTAssertEqual(ChatRoomPlan.unreadCount(messages, lastReadAt: read), 2)
    }

    func testDefaultTitleNumbersDuplicates() {
        XCTAssertEqual(ChatRoomPlan.defaultTitle(base: "聊天室", existing: []), "聊天室")
        XCTAssertEqual(ChatRoomPlan.defaultTitle(base: "聊天室", existing: ["聊天室"]), "聊天室 2")
        XCTAssertEqual(ChatRoomPlan.defaultTitle(base: "聊天室", existing: ["聊天室", "聊天室 2"]), "聊天室 3")
    }

    /// 只推自己发的、还没推过(或改过)的;房间名改了也推;从不删消息。
    func testChatPushPlanOnlyPushesOwnNewMessages() {
        let roomID = UUID()
        let room = ChatRoom(uuid: roomID, title: "群")
        let roomSnapshot = SharedChatMapping.snapshot(of: room)
        let sent = SharedChatMapping.snapshot(of: ChatRoomMessage(roomUUID: roomID, content: "a"))
        let fresh = SharedChatMapping.snapshot(of: ChatRoomMessage(roomUUID: roomID, content: "b"))
        let gone = UUID()  // 账本里有、本地已经没有的一条(别人的,或者去重删掉的)
        let ledger: [UUID: SharedLedgerRecord] = [
            roomID: SharedLedgerRecord(type: .chatRoom, fields: roomSnapshot.fields),
            sent.uuid: SharedLedgerRecord(type: .chatMessage, fields: sent.fields),
            gone: SharedLedgerRecord(type: .chatMessage, fields: [:]),
        ]
        let plan = SharedChatPlanner.pushPlan(room: roomSnapshot, myMessages: [sent, fresh], ledger: ledger)
        XCTAssertEqual(plan.saves, [fresh.uuid])
        XCTAssertEqual(plan.deletes, [])

        room.title = "京都群"
        let renamed = SharedChatPlanner.pushPlan(room: SharedChatMapping.snapshot(of: room),
                                                 myMessages: [sent], ledger: ledger)
        XCTAssertEqual(renamed.saves, [roomID])
    }

    func testCardMessageRoundTrip() throws {
        let tripID = UUID()
        let card = ChatCard(reference: AgentReference(kind: .trip, id: tripID, title: "京都"),
                            body: "第 1 天\n伏见稻荷\n\n祇园\n第 2 天\n岚山",
                            shareURL: "https://www.icloud.com/share/abc")
        let message = ChatRoomMessage(roomUUID: UUID(), kind: .card, content: card.summaryLine)
        message.cardData = card.encoded
        let snapshot = SharedChatMapping.snapshot(of: message)

        let copy = ChatRoomMessage(roomUUID: message.roomUUID, content: "")
        SharedChatMapping.apply(snapshot.fields, to: copy)
        XCTAssertEqual(copy.kind, .card)
        XCTAssertEqual(copy.card, card)
        XCTAssertEqual(copy.content, "旅行:京都")
        XCTAssertEqual(SharedChatMapping.snapshot(of: copy).fields, snapshot.fields)
        XCTAssertEqual(ChatMessageKind.card.rawValue, "card")
    }

    func testCardPreviewSkipsBlankLinesAndTruncates() {
        let card = ChatCard(reference: AgentReference(kind: .trip, id: UUID(), title: "x"),
                            body: "a\n\n b \nc\nd")
        XCTAssertEqual(card.preview(maxLines: 3), "a\nb\nc\n…")
        XCTAssertEqual(card.preview(maxLines: 4), "a\nb\nc\nd")
        XCTAssertNil(ChatCard.decode(Data("x".utf8)))
    }
}
