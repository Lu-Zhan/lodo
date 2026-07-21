import XCTest
@testable import LodoCore

/// DeepSeekClient.parseCommand 离线单测(不发网络请求),覆盖待办四种操作 +
/// 记忆两种操作(memorize/ask_memory)的解析与归一化兜底。
final class CommandParseTests: XCTestCase {
    private func taskPayload(
        action: String, uuid: String? = nil,
        title: String = "开会", remindAt: String = "2026-07-08 09:00"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "action": action, "title": title, "remind_at": remindAt,
            "all_day": false, "duration_minutes": 0,
            "repeat_type": "none", "repeat_days": [], "repeat_times": []
        ]
        if let uuid { payload["uuid"] = uuid }
        return payload
    }

    // MARK: - 原有四种操作(memoryEnabled 开关不影响)

    func testCreateAction() throws {
        let payload: [String: Any] = ["actions": [taskPayload(action: "create")]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .actions(let actions) = result, actions.count == 1,
              case .create(let parsed) = actions[0] else {
            XCTFail("expected single create action")
            return
        }
        XCTAssertEqual(parsed.title, "开会")
    }

    func testUpdateActionRequiresValidUUID() {
        let payload: [String: Any] = ["actions": [taskPayload(action: "update", uuid: "missing")]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: ["a"], memoryEnabled: false))
    }

    func testUpdateActionWithValidUUID() throws {
        let payload: [String: Any] = ["actions": [taskPayload(action: "update", uuid: "a")]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: ["a"], memoryEnabled: false)
        guard case .actions(let actions) = result, actions.count == 1,
              case .update(let uuid, _) = actions[0] else {
            XCTFail("expected single update action")
            return
        }
        XCTAssertEqual(uuid, "a")
    }

    func testCompleteAction() throws {
        let payload: [String: Any] = ["actions": [["action": "complete", "uuid": "a"]]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: ["a"], memoryEnabled: false)
        guard case .actions(let actions) = result, actions.count == 1,
              case .complete(let uuid) = actions[0] else {
            XCTFail("expected single complete action")
            return
        }
        XCTAssertEqual(uuid, "a")
    }

    func testDeleteActionInvalidUUIDThrows() {
        let payload: [String: Any] = ["actions": [["action": "delete", "uuid": "missing"]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: ["a"], memoryEnabled: false))
    }

    func testClarifyPassthrough() throws {
        let payload: [String: Any] = [
            "question": "什么时候提醒你交材料?",
            "options": ["明天 09:00", "明天 14:00"]
        ]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .clarify(let question, let options) = result else {
            XCTFail("expected clarify")
            return
        }
        XCTAssertEqual(question, "什么时候提醒你交材料?")
        XCTAssertEqual(options, ["明天 09:00", "明天 14:00"])
    }

    func testMissingActionsThrows() {
        let payload: [String: Any] = [:]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    func testEmptyActionsThrows() {
        let payload: [String: Any] = ["actions": []]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    func testUnknownActionThrows() {
        let payload: [String: Any] = ["actions": [["action": "unknown"]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    // MARK: - memorize(收藏)

    func testMemorizeValidWhenEnabled() throws {
        let payload: [String: Any] = ["actions": [["action": "memorize", "text": "wifi密码是8888"]]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .memorize(let text) = actions[0] else {
            XCTFail("expected single memorize action")
            return
        }
        XCTAssertEqual(text, "wifi密码是8888")
    }

    func testMemorizeEmptyTextThrows() {
        let payload: [String: Any] = ["actions": [["action": "memorize", "text": "  "]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true))
    }

    func testMemorizeWhenDisabledThrowsUnknownAction() {
        // memoryEnabled == false(如 Watch)时,即使模型幻觉出 memorize,也按未知 action 处理,
        // 保持旧行为字节级不变。
        let payload: [String: Any] = ["actions": [["action": "memorize", "text": "wifi密码是8888"]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    // MARK: - ask_memory(查记忆)+ 归一化兜底

    func testAskMemoryAlone() throws {
        let payload: [String: Any] = ["actions": [["action": "ask_memory", "question": "wifi密码是多少"]]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .askMemory(let question) = actions[0] else {
            XCTFail("expected single askMemory action")
            return
        }
        XCTAssertEqual(question, "wifi密码是多少")
    }

    func testAskMemoryEmptyQuestionThrows() {
        let payload: [String: Any] = ["actions": [["action": "ask_memory", "question": ""]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true))
    }

    func testAskMemoryWhenDisabledThrowsUnknownAction() {
        let payload: [String: Any] = ["actions": [["action": "ask_memory", "question": "wifi密码是多少"]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    /// 模型不守"ask_memory 单独出现"的规则、返回多条 ask_memory 时,只留第一条。
    func testMultipleAskMemoryCollapsesToFirst() throws {
        let payload: [String: Any] = ["actions": [
            ["action": "ask_memory", "question": "问题一"],
            ["action": "ask_memory", "question": "问题二"]
        ]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .askMemory(let question) = actions[0] else {
            XCTFail("expected single askMemory action")
            return
        }
        XCTAssertEqual(question, "问题一")
    }

    /// ask_memory 与写操作混在一句话里返回时,丢弃 ask_memory 只留写操作
    /// (查询可以重问,新建不能丢)。
    func testAskMemoryMixedWithCreateDropsAskMemory() throws {
        let payload: [String: Any] = ["actions": [
            taskPayload(action: "create"),
            ["action": "ask_memory", "question": "问题一"]
        ]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result else {
            XCTFail("expected actions")
            return
        }
        XCTAssertEqual(actions.count, 1)
        guard case .create = actions[0] else {
            XCTFail("expected remaining action to be create")
            return
        }
    }

    /// 一句话里同时收藏 + 新建:两条操作都保留(memorize 不受归一化影响)。
    func testMemorizeCoexistsWithCreate() throws {
        let payload: [String: Any] = ["actions": [
            taskPayload(action: "create"),
            ["action": "memorize", "text": "门禁码1234"]
        ]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result else {
            XCTFail("expected actions")
            return
        }
        XCTAssertEqual(actions.count, 2)
    }

    // MARK: - ReAct 工具调用(search_memory)

    func testToolCallSearchMemory() throws {
        let payload: [String: Any] = [
            "thought": "需要先看看装备清单写了什么", "tool": "search_memory", "query": "爬山装备清单"
        ]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .toolCall(let thought, .searchMemory(let query)) = result else {
            XCTFail("expected toolCall(.searchMemory)")
            return
        }
        XCTAssertEqual(thought, "需要先看看装备清单写了什么")
        XCTAssertEqual(query, "爬山装备清单")
    }

    func testToolCallMissingQueryThrows() {
        let payload: [String: Any] = ["thought": "…", "tool": "search_memory"]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true))
    }

    func testToolCallUnknownToolThrows() {
        let payload: [String: Any] = ["tool": "search_web", "query": "x"]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true))
    }

    /// memoryEnabled == false(Watch)时 prompt 里没提过这个选项,模型幻觉出来也不认,
    /// 落到 actions 解析(这里没给 actions,按"缺少 actions"报错)。
    func testToolCallIgnoredWhenMemoryDisabled() {
        let payload: [String: Any] = ["tool": "search_memory", "query": "爬山装备清单"]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }
}
