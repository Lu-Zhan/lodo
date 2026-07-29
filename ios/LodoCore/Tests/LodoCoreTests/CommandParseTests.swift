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

    // MARK: - ask(反问)

    /// 反问题目的原始 JSON;options 缺省给两个,recommended 落在第一个。
    private func askQuestionPayload(
        question: String = "什么时候提醒你交材料?", header: String = "提醒时间",
        multiSelect: Bool = false, options: [[String: Any]]? = nil
    ) -> [String: Any] {
        [
            "header": header, "question": question, "multi_select": multiSelect,
            "options": options ?? [
                ["label": "明天 09:00", "description": "上班后第一件事", "recommended": true],
                ["label": "今晚 20:00", "description": "今天之内交掉"]
            ]
        ]
    }

    func testAskParsesQuestionsAndOptions() throws {
        let payload: [String: Any] = ["ask": [
            askQuestionPayload(),
            askQuestionPayload(question: "要带哪些材料?", header: "材料", multiSelect: true)
        ]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .ask(let questions) = result, questions.count == 2 else {
            XCTFail("expected two ask questions")
            return
        }
        XCTAssertEqual(questions[0].header, "提醒时间")
        XCTAssertEqual(questions[0].question, "什么时候提醒你交材料?")
        XCTAssertFalse(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.count, 2)
        XCTAssertEqual(questions[0].options[0].label, "明天 09:00")
        XCTAssertEqual(questions[0].options[0].description, "上班后第一件事")
        XCTAssertTrue(questions[0].options[0].recommended)
        XCTAssertFalse(questions[0].options[1].recommended)
        XCTAssertTrue(questions[1].multiSelect)
    }

    /// 没有选项、或问题文案为空的题目直接丢掉,其余题目照常返回。
    func testAskDropsUnusableQuestions() throws {
        let payload: [String: Any] = ["ask": [
            askQuestionPayload(question: "  ", header: "空问题"),
            askQuestionPayload(header: "没选项", options: []),
            askQuestionPayload(question: "什么时候提醒?", header: "提醒时间")
        ]]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .ask(let questions) = result, questions.count == 1 else {
            XCTFail("expected only the usable question")
            return
        }
        XCTAssertEqual(questions[0].question, "什么时候提醒?")
    }

    func testAskWithNoUsableQuestionThrows() {
        let payload: [String: Any] = ["ask": [askQuestionPayload(options: [])]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    /// 模型同时给了 ask 和 actions 时以 ask 为准(信息还没问全,不能先落库)。
    func testAskTakesPrecedenceOverActions() throws {
        let payload: [String: Any] = [
            "ask": [askQuestionPayload()],
            "actions": [taskPayload(action: "create")]
        ]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .ask = result else {
            XCTFail("expected ask to win")
            return
        }
    }

    /// 题目/选项超量时按上限截断,不整体报错。
    func testAskClampsQuestionAndOptionCount() throws {
        let manyOptions = (1...9).map { ["label": "选项\($0)"] }
        let payload: [String: Any] = [
            "ask": (1...6).map { askQuestionPayload(question: "问题\($0)", options: manyOptions) }
        ]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false)
        guard case .ask(let questions) = result else {
            XCTFail("expected ask")
            return
        }
        XCTAssertEqual(questions.count, 4)
        XCTAssertEqual(questions[0].options.count, 6)
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

    // MARK: - suggest_memorize(AI 主动建议收藏)

    func testSuggestMemorizeValidWhenEnabled() throws {
        let payload: [String: Any] = [
            "actions": [["action": "suggest_memorize", "text": "周三下午一般没空"]]
        ]
        let result = try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .suggestMemorize(let text) = actions[0] else {
            XCTFail("expected single suggestMemorize action")
            return
        }
        XCTAssertEqual(text, "周三下午一般没空")
    }

    func testSuggestMemorizeEmptyTextThrows() {
        let payload: [String: Any] = ["actions": [["action": "suggest_memorize", "text": "  "]]]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: true))
    }

    func testSuggestMemorizeWhenDisabledThrowsUnknownAction() {
        let payload: [String: Any] = [
            "actions": [["action": "suggest_memorize", "text": "周三下午一般没空"]]
        ]
        XCTAssertThrowsError(
            try DeepSeekClient.parseCommand(payload, validUUIDs: [], memoryEnabled: false))
    }

    /// suggest_memorize 是信息类操作(和 ask_memory/answer 同一组),与写操作混在
    /// 一句话里返回时应该被丢弃,不像 memorize 那样可以共存。
    func testSuggestMemorizeMixedWithCreateDropsSuggestion() throws {
        let payload: [String: Any] = ["actions": [
            taskPayload(action: "create"),
            ["action": "suggest_memorize", "text": "周三下午一般没空"]
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

    // MARK: - ReAct 工具调用(web_search)+ answer 操作

    func testToolCallWebSearch() throws {
        let payload: [String: Any] = [
            "thought": "需要查最新价格", "tool": "web_search", "query": "iPhone 17 Pro 价格"
        ]
        let result = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true)
        guard case .toolCall(let thought, .webSearch(let query)) = result else {
            XCTFail("expected toolCall(.webSearch)")
            return
        }
        XCTAssertEqual(thought, "需要查最新价格")
        XCTAssertEqual(query, "iPhone 17 Pro 价格")
    }

    func testToolCallWebSearchMissingQueryThrows() {
        let payload: [String: Any] = ["thought": "…", "tool": "web_search"]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true))
    }

    /// webSearchEnabled == false 时 prompt 里没提过这个选项,模型幻觉出来也不认。
    func testToolCallWebSearchIgnoredWhenDisabled() {
        let payload: [String: Any] = ["tool": "web_search", "query": "x"]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: false))
    }

    // MARK: - ReAct 工具调用(web_fetch)

    func testToolCallWebFetch() throws {
        let payload: [String: Any] = [
            "thought": "用户给了链接,需要看内容", "tool": "web_fetch",
            "url": "https://example.com/article"
        ]
        let result = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true)
        guard case .toolCall(let thought, .webFetch(let url)) = result else {
            XCTFail("expected toolCall(.webFetch)")
            return
        }
        XCTAssertEqual(thought, "用户给了链接,需要看内容")
        XCTAssertEqual(url, "https://example.com/article")
    }

    func testToolCallWebFetchMissingURLThrows() {
        let payload: [String: Any] = ["thought": "…", "tool": "web_fetch"]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true))
    }

    /// webSearchEnabled == false 时 prompt 里没提过这个选项,模型幻觉出来也不认。
    func testToolCallWebFetchIgnoredWhenDisabled() {
        let payload: [String: Any] = ["tool": "web_fetch", "url": "https://example.com"]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: false))
    }

    func testAnswerActionAlone() throws {
        let payload: [String: Any] = ["actions": [["action": "answer", "text": "今天多云转晴"]]]
        let result = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .answer(let text) = actions[0] else {
            XCTFail("expected single answer action")
            return
        }
        XCTAssertEqual(text, "今天多云转晴")
    }

    func testAnswerEmptyTextThrows() {
        let payload: [String: Any] = ["actions": [["action": "answer", "text": "  "]]]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true))
    }

    /// webSearchEnabled == false 时,即使模型幻觉出 answer,也按未知 action 处理。
    func testAnswerWhenDisabledThrowsUnknownAction() {
        let payload: [String: Any] = ["actions": [["action": "answer", "text": "今天多云转晴"]]]
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: false))
    }

    /// answer 与写操作混在一句话里返回时,丢弃 answer 只留写操作。
    func testAnswerMixedWithCreateDropsAnswer() throws {
        let payload: [String: Any] = ["actions": [
            taskPayload(action: "create"),
            ["action": "answer", "text": "顺带回答"]
        ]]
        let result = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, webSearchEnabled: true)
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

    /// ask_memory 与 answer 混在一起(两者都是"问答类"操作)时只留第一条。
    func testAskMemoryAndAnswerCollapsesToFirst() throws {
        let payload: [String: Any] = ["actions": [
            ["action": "ask_memory", "question": "问题一"],
            ["action": "answer", "text": "回答二"]
        ]]
        let result = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: true, webSearchEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .askMemory(let question) = actions[0] else {
            XCTFail("expected single askMemory action (first informational one)")
            return
        }
        XCTAssertEqual(question, "问题一")
    }
}
