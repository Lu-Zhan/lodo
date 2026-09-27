import XCTest
@testable import LodoCore

/// AI 倒数日操作的解析(不发请求)。
final class CountdownCommandTests: XCTestCase {
    private let id = UUID()

    private func parse(_ actions: [[String: Any]], enabled: Bool = true) throws -> AICommandResult {
        try DeepSeekClient.parseCommand(["actions": actions], validUUIDs: ["t1"],
                                        memoryEnabled: false, countdownEnabled: enabled,
                                        validCountdownIDs: [id.uuidString])
    }

    private func ops(_ result: AICommandResult) -> [CountdownOp] {
        guard case .actions(let actions) = result else { return [] }
        return actions.compactMap { if case .countdown(let op) = $0 { return op } else { return nil } }
    }

    func testCreateAllDayByDefaultWhenNoTime() throws {
        let result = try parse([["action": "create_countdown", "title": "考试",
                                 "start": "2026-07-20", "start_reminders": [1440, 0, 1440, -5]]])
        guard case .create(let draft) = ops(result).first else { return XCTFail() }
        XCTAssertEqual(draft.title, "考试")
        XCTAssertTrue(draft.allDay)
        XCTAssertEqual(draft.startReminders, [0, 1440], "去重、去负数、排序")
        XCTAssertNil(draft.showInWidget)
    }

    func testCreateTimedWithRangeDropsBackwardsEnd() throws {
        let result = try parse([["action": "create_countdown", "title": "演唱会",
                                 "start": "2026-07-20 19:30", "end": "2026-07-19",
                                 "end_reminders": [60], "show_in_widget": true]])
        guard case .create(let draft) = ops(result).first else { return XCTFail() }
        XCTAssertFalse(draft.allDay)
        XCTAssertNil(draft.end, "结束早于开始的丢掉")
        XCTAssertEqual(draft.endReminders, [], "没有结束就没有结束提醒")
        XCTAssertEqual(draft.showInWidget, true)
    }

    func testUpdateAndDeleteRequireKnownID() throws {
        let result = try parse([
            ["action": "update_countdown", "id": id.uuidString, "start": "2026-08-01", "end": ""],
            ["action": "delete_countdown", "id": id.uuidString],
        ])
        XCTAssertEqual(ops(result), [
            .update(id: id, change: CountdownChange(
                start: DeepSeekClient.countdownDate("2026-08-01"), end: .clear)),
            .delete(id: id),
        ])
        XCTAssertThrowsError(try parse([["action": "delete_countdown", "id": UUID().uuidString]]))
    }

    /// 和待办写操作、回答混在一起时两样都留(倒数日排前面);没开能力时按未知 action 报错。
    func testMixedWithOtherActionsKeepsBoth() throws {
        let result = try parse([
            ["action": "complete", "uuid": "t1"],
            ["action": "create_countdown", "title": "考试", "start": "2026-07-20"],
        ])
        guard case .actions(let actions) = result else { return XCTFail() }
        XCTAssertEqual(actions.count, 2)
        guard case .countdown = actions[0], case .complete = actions[1] else { return XCTFail() }
        let withAnswer = try parse([
            ["action": "create_countdown", "title": "考试", "start": "2026-07-20"],
            ["action": "answer", "text": "好的"],
        ])
        guard case .actions(let both) = withAnswer else { return XCTFail() }
        XCTAssertEqual(both.count, 2)
        XCTAssertThrowsError(try parse([["action": "create_countdown", "title": "考试",
                                         "start": "2026-07-20"]], enabled: false))
    }

    func testTranscriptListsChanges() {
        let event = BackupCountdownEvent(
            uuid: id, title: "考试", startDate: DeepSeekClient.countdownDate("2026-07-20")!,
            endDate: nil, allDay: true, notes: "", startReminders: [], endReminders: [],
            showInWidget: false, createdAt: .now)
        let record = CountdownEditRecord(created: [event])
        XCTAssertEqual(record.transcript, "新建倒数日:「考试」2026-07-20")
        XCTAssertTrue(record.hasChanges)
    }
}
