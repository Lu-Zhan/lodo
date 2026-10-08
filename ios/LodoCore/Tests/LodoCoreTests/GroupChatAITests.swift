import XCTest
@testable import LodoCore

/// 共享聊天室里的 AI:聊天记录拼装、群聊 prompt、提案编码、解析时不做互斥归一化。不发请求。
final class GroupChatAITests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testTranscriptFormatsEachKind() {
        let text = ChatTranscript.build([
            .init(sender: "", isMe: false, kind: .system, content: "小林加入了", createdAt: at(0)),
            .init(sender: "小林", isMe: false, kind: .text, content: "3 号出发?", createdAt: at(1)),
            .init(sender: "", isMe: true, kind: .text, content: "可以", createdAt: at(2)),
            .init(sender: "阿杰", isMe: false, kind: .ai, content: "排好了", createdAt: at(3)),
            .init(sender: "阿杰", isMe: false, kind: .card, content: "旅行:京都",
                  cardBody: "第 1 天:伏见稻荷", createdAt: at(4)),
        ], calendar: utc)
        XCTAssertEqual(text, """
        [06-01 00:00] (系统)小林加入了
        [06-01 00:01] 小林:3 号出发?
        [06-01 00:02] 我:可以
        [06-01 00:03] 阿杰的 AI:排好了
        [06-01 00:04] 阿杰 分享了「旅行:京都」:
        第 1 天:伏见稻荷
        """)
    }

    /// 超过条数/字数上限时丢最早的;卡片快照单独截断。
    func testTranscriptKeepsNewestWithinLimits() {
        let entries = (0..<10).map {
            ChatTranscript.Entry(sender: "A", isMe: false, kind: .text, content: "m\($0)", createdAt: at(Double($0)))
        }
        let byCount = ChatTranscript.build(entries, maxMessages: 3, calendar: utc)
        XCTAssertEqual(byCount.components(separatedBy: "\n").map { $0.components(separatedBy: ":").last! },
                       ["m7", "m8", "m9"])
        let byChars = ChatTranscript.build(entries, maxChars: 50, calendar: utc)
        XCTAssertTrue(byChars.hasSuffix("A:m9"))
        XCTAssertFalse(byChars.contains("m0"))

        let card = ChatTranscript.build([
            .init(sender: "A", isMe: false, kind: .card, content: "旅行:x",
                  cardBody: String(repeating: "长", count: 20), createdAt: at(0)),
        ], cardBodyLimit: 5, calendar: utc)
        XCTAssertTrue(card.hasSuffix("长长长长长…"))
    }

    func testProposalRoundTripThroughMessagePayload() {
        let proposal = ChatProposal(
            tripEdit: TripEdit(tripTitle: "京都", summary: "第三天加清水寺",
                               removeIDs: [UUID()],
                               updates: [TripEditUpdate(id: UUID(), title: "清水寺")]),
            tasks: [ParsedTask(title: "订酒店", remindAt: now, allDay: false, repeatType: .none,
                               repeatDays: [], repeatTimes: [])],
            countdowns: [CountdownDraft(title: "出发", start: now)])
        let message = ChatRoomMessage(roomUUID: UUID(), kind: .ai, content: "整理好了")
        message.proposalData = proposal.encoded
        let snapshot = SharedChatMapping.snapshot(of: message)
        let copy = ChatRoomMessage(roomUUID: message.roomUUID, content: "")
        SharedChatMapping.apply(snapshot.fields, to: copy)
        XCTAssertEqual(copy.proposal, proposal)
        XCTAssertFalse(proposal.isEmpty)
        XCTAssertTrue(ChatProposal().isEmpty)
    }

    /// 群聊里「回一句 + 新建任务」都留着;普通模式下 answer 混着写操作会被丢掉。
    func testGroupChatKeepsInformationalAndWriteActionsTogether() throws {
        let payload: [String: Any] = ["actions": [
            ["action": "answer", "text": "我把订酒店记给你了"],
            ["action": "create", "title": "订酒店", "remind_at": "2026-07-01 09:00", "all_day": false,
             "repeat_type": "none", "repeat_days": [], "repeat_times": []],
        ]]
        guard case .actions(let normal) = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true, now: now) else {
            return XCTFail("expected actions")
        }
        XCTAssertEqual(normal.count, 1)
        guard case .actions(let group) = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true,
            keepsAllActions: true, now: now) else {
            return XCTFail("expected actions")
        }
        XCTAssertEqual(group.count, 2)
        guard case .answer = group[0], case .create = group[1] else {
            return XCTFail("expected answer + create")
        }
    }

    /// 群聊段拼在末尾;私人偏好不带(回复全房间都看得到)。
    func testGroupChatBlockInSystemPrompt() {
        let block = GroupChatPrompt.block(roomTitle: "京都五人行")
        XCTAssertTrue(block.contains("「京都五人行」"))
        let caps = DeepSeekClient.CommandCapabilities(tripPlan: true, countdown: true)
        let (withGroup, _) = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: caps, groupChat: block)
        let (plain, _) = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: caps)
        XCTAssertTrue(withGroup.contains(block))
        XCTAssertFalse(plain.contains("群聊模式"))
    }

    func testNotificationOnlyForFreshMessagesFromOthers() {
        func check(_ fromMe: Bool = false, ageMinutes: Double = 1, muted: Bool = false,
                   viewing: Bool = false) -> Bool {
            ChatNotificationPlan.shouldNotify(fromMe: fromMe, createdAt: at(-ageMinutes), now: now,
                                              muted: muted, viewingRoom: viewing)
        }
        XCTAssertTrue(check())
        XCTAssertFalse(check(true))
        XCTAssertFalse(check(ageMinutes: 30), "刚加入时拉下来的历史消息不提醒")
        XCTAssertFalse(check(muted: true))
        XCTAssertFalse(check(viewing: true))
    }

    func testNotificationBody() {
        XCTAssertEqual(ChatNotificationPlan.line(sender: "小林", kind: .text, content: "到了吗"), "小林: 到了吗")
        XCTAssertEqual(ChatNotificationPlan.line(sender: "", kind: .system, content: "小林写入了行程"), "小林写入了行程")
        XCTAssertEqual(ChatNotificationPlan.body(lines: ["a"], moreFormat: { "共 \($0) 条" }), "a")
        XCTAssertEqual(ChatNotificationPlan.body(lines: ["a", "b"], moreFormat: { "共 \($0) 条" }), "b\n共 2 条")
        XCTAssertNil(ChatNotificationPlan.body(lines: [], moreFormat: { "\($0)" }))
    }
}
