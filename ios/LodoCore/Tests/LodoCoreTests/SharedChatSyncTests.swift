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

    /// 消息只看账本里有没有;房间名改了才推房间;从不删消息。
    func testChatPushPlanOnlyPushesOwnNewMessages() {
        let roomID = UUID()
        let room = ChatRoom(uuid: roomID, title: "群")
        let roomSnapshot = SharedChatMapping.snapshot(of: room)
        let sent = UUID(), fresh = UUID()
        let gone = UUID()  // 账本里有、本地已经没有的一条(别人的,或者去重删掉的)
        let ledger: [UUID: SharedLedgerRecord] = [
            roomID: SharedLedgerRecord(type: .chatRoom, fields: roomSnapshot.fields),
            sent: .stored(type: .chatMessage, fields: ["content": .string("a")], systemFields: Data([1])),
            gone: .stored(type: .chatMessage, fields: [:], systemFields: nil),
        ]
        let plan = SharedChatPlanner.pushPlan(room: roomSnapshot, myMessages: [sent, fresh], ledger: ledger)
        XCTAssertEqual(plan.saves, [fresh])
        XCTAssertEqual(plan.deletes, [])

        room.title = "京都群"
        let renamed = SharedChatPlanner.pushPlan(room: SharedChatMapping.snapshot(of: room),
                                                 myMessages: [sent], ledger: ledger)
        XCTAssertEqual(renamed.saves, [roomID])
    }

    /// 账本里聊天消息只记"有这条",不存正文和系统字段;别的类型照旧整份存。
    func testLedgerStoresChatMessagesCompactly() {
        let message = SharedLedgerRecord.stored(type: .chatMessage, fields: ["content": .string("长长的正文")],
                                                systemFields: Data([1, 2, 3]))
        XCTAssertEqual(message.fields, [:])
        XCTAssertNil(message.systemFields)
        let trip = SharedLedgerRecord.stored(type: .trip, fields: ["title": .string("京都")], systemFields: Data([1]))
        XCTAssertEqual(trip.fields, ["title": .string("京都")])
        XCTAssertEqual(trip.systemFields, Data([1]))
    }

    func testAttachmentAndAskFieldsRoundTrip() {
        let roomID = UUID()
        let message = ChatRoomMessage(roomUUID: roomID, kind: .file, content: "行程单.pdf")
        message.fileName = "行程单.pdf"
        message.filePath = SharedChatMapping.attachmentPath(roomUUID: roomID, messageUUID: message.uuid,
                                                             fileName: "行程单.pdf")
        XCTAssertTrue(message.filePath.hasSuffix(".pdf"))
        XCTAssertTrue(message.filePath.hasPrefix("Chat/\(roomID.uuidString)/"))
        message.askData = try? JSONEncoder().encode(AgentAskSnapshot(questions: [
            AskQuestion(question: "住哪?", options: [AskOption(label: "京都站")])]))
        message.replyData = ChatAskReply(askID: UUID(), answers: [["京都站"]]).encoded
        message.refRaw = ChatProposalRef(messageID: UUID(), part: "plan", action: .applied).raw
        message.senderID = "_abc"
        let copy = ChatRoomMessage(roomUUID: roomID, content: "")
        SharedChatMapping.apply(SharedChatMapping.snapshot(of: message).fields, to: copy)
        XCTAssertEqual(copy.fileName, "行程单.pdf")
        XCTAssertEqual(copy.filePath, SharedChatMapping.attachmentPath(roomUUID: roomID, messageUUID: copy.uuid,
                                                                        fileName: "行程单.pdf"))
        XCTAssertEqual(copy.ask?.questions.first?.question, "住哪?")
        XCTAssertEqual(copy.reply, message.reply)
        XCTAssertEqual(copy.ref, message.ref)
        XCTAssertEqual(copy.senderID, "", "senderID 不进 payload")
    }

    func testProposalRefParseAndLatest() {
        let id = UUID()
        let applied = ChatProposalRef(messageID: id, part: "plan", action: .applied)
        XCTAssertEqual(ChatProposalRef(raw: applied.raw), applied)
        XCTAssertNil(ChatProposalRef(raw: "x|plan|applied"))
        XCTAssertNil(ChatProposalRef(raw: id.uuidString + "|plan|done"))
        let t0 = Date(timeIntervalSince1970: 0)
        let refs: [(ref: ChatProposalRef, by: String, fromMe: Bool, at: Date)] = [
            (applied, "小林", false, t0),
            (ChatProposalRef(messageID: id, part: "plan", action: .reverted), "小林", false, t0.addingTimeInterval(5)),
            (ChatProposalRef(messageID: id, part: "edit", action: .applied), "", true, t0),
        ]
        XCTAssertEqual(ChatProposalRef.latest(refs, messageID: id, part: "plan")?.action, .reverted)
        XCTAssertEqual(ChatProposalRef.latest(refs, messageID: id, part: "edit")?.fromMe, true)
        XCTAssertNil(ChatProposalRef.latest(refs, messageID: UUID(), part: "plan"))
    }

    func testAskTally() {
        let who = ChatAskTally.respondents([("a", false), ("a", false), ("", true), ("b", false)])
        XCTAssertEqual(who, ["a", "b", "me"])
        XCTAssertTrue(ChatAskTally.isComplete(answered: 3, memberCount: 3))
        XCTAssertFalse(ChatAskTally.isComplete(answered: 2, memberCount: 3))
        XCTAssertFalse(ChatAskTally.isComplete(answered: 2, memberCount: nil))
        XCTAssertEqual(ChatAskTally.questionList([AskQuestion(question: "住哪?", options: []),
                                                  AskQuestion(question: "几号走?", options: [])]),
                       "1. 住哪?\n2. 几号走?")
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

    func testRecallWindowAndKinds() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ChatRecall.canRecall(fromMe: true, kind: .text, createdAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(ChatRecall.canRecall(fromMe: true, kind: .text, createdAt: now.addingTimeInterval(-180), now: now))
        XCTAssertFalse(ChatRecall.canRecall(fromMe: false, kind: .text, createdAt: now, now: now))
        XCTAssertFalse(ChatRecall.canRecall(fromMe: true, kind: .ai, createdAt: now, now: now))
        XCTAssertTrue(ChatRecall.canRecall(fromMe: true, kind: .image, createdAt: now, now: now))
    }

    /// 对方 payload 里的路径不用:收到的一端按房间 + 消息 uuid + 扩展名重算。
    func testIncomingFilePathIsRecomputedLocally() {
        let roomID = UUID()
        let evil = ChatRoomMessage(roomUUID: roomID, kind: .file, content: "x")
        evil.fileName = "a.pdf"
        var fields = SharedChatMapping.snapshot(of: evil).fields
        fields["filePath"] = .string("lodo.store")
        fields["fileName"] = .string("../../x.st/ore")
        let copy = ChatRoomMessage(uuid: UUID(), roomUUID: roomID, content: "")
        SharedChatMapping.apply(fields, to: copy)
        XCTAssertTrue(copy.filePath.hasPrefix("Chat/\(roomID.uuidString)/\(copy.uuid.uuidString)"))
        XCTAssertFalse(copy.filePath.contains(".."))
        XCTAssertEqual(SharedChatMapping.attachmentPath(roomUUID: roomID, messageUUID: copy.uuid, fileName: "a.P/D-F"),
                       "Chat/\(roomID.uuidString)/\(copy.uuid.uuidString)")
    }

    func testSharedTripFilePathsAreValidated() {
        XCTAssertEqual(SharedFilePath.safe("Memory/abc.pdf"), "Memory/abc.pdf")
        XCTAssertEqual(SharedFilePath.safe("Contacts/a.jpg"), "Contacts/a.jpg")
        XCTAssertNil(SharedFilePath.safe("lodo.store"))
        XCTAssertNil(SharedFilePath.safe("Memory/../lodo.store"))
        XCTAssertNil(SharedFilePath.safe("../Memory/a"))
        XCTAssertNil(SharedFilePath.safe("Memory/"))
        XCTAssertNil(SharedFilePath.safe("Memory/.hidden"))
        XCTAssertNil(SharedFilePath.safe("Other/a"))
        let item = MemoryItem(kind: .file)
        SharedTripMapping.apply(["relativeFilePath": .string("lodo.store"),
                                 "attachmentRelativePaths": .strings(["Contacts/ok.jpg", "../x"])], to: item)
        XCTAssertNil(item.relativeFilePath)
        XCTAssertEqual(item.attachmentRelativePaths, ["Contacts/ok.jpg"])
    }

    func testMarkerIsSkippedInTranscript() {
        let now = Date()
        let text = ChatTranscript.build([
            .init(sender: "", isMe: true, kind: .marker, content: "x", createdAt: now),
            .init(sender: "A", isMe: false, kind: .text, content: "hi", createdAt: now),
        ])
        XCTAssertFalse(text.contains("x"))
        XCTAssertTrue(text.hasSuffix("A:hi"))
        XCTAssertFalse(ChatRecall.canRecall(fromMe: true, kind: .marker, createdAt: now, now: now))
    }
}
