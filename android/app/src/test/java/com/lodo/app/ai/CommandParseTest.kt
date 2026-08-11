package com.lodo.app.ai

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** DeepSeekClient.parseCommandResult 离线单测(不发网络请求),1:1 移植自
 * ios/LodoCore/Tests/LodoCoreTests/CommandParseTests.swift 里和 Android 已对齐
 * 的部分(create/update/complete/delete/answer/web_search/web_fetch/memorize/
 * suggest_memorize/ask_memory/search_memory)。Android 没有 auto_memorize/
 * remember_preference(iOS 独有,见 CLAUDE.md),不移植那两部分。 */
class CommandParseTest {
    private fun taskPayload(
        action: String, uuid: String? = null,
        title: String = "开会", remindAt: String = "2026-07-08 09:00",
    ): JSONObject {
        val payload = JSONObject()
            .put("action", action)
            .put("title", title)
            .put("remind_at", remindAt)
            .put("all_day", false)
            .put("duration_minutes", 0)
            .put("repeat_type", "none")
            .put("repeat_days", JSONArray())
            .put("repeat_times", JSONArray())
        uuid?.let { payload.put("uuid", it) }
        return payload
    }

    private fun payloadWithActions(vararg actions: JSONObject): JSONObject =
        JSONObject().put("actions", JSONArray(actions.toList()))

    // ---- 原有四种操作 ----

    @Test
    fun createAction() {
        val payload = payloadWithActions(taskPayload("create"))
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
        val actions = (result as? AICommandResult.Actions)?.actions
            ?: return fail("expected actions")
        assertEquals(1, actions.size)
        val create = actions[0] as? AIAction.Create ?: return fail("expected create")
        assertEquals("开会", create.task.title)
    }

    @Test(expected = DeepSeekException::class)
    fun createActionRejectsBlankTitle() {
        val payload = payloadWithActions(taskPayload("create", title = "   "))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
    }

    @Test(expected = DeepSeekException::class)
    fun createActionRejectsOutOfRangeRepeatDays() {
        val task = taskPayload("create").put("repeat_days", JSONArray(listOf(7)))
        DeepSeekClient.parseCommandResult(
            payloadWithActions(task), emptySet(), webSearchEnabled = false)
    }

    @Test
    fun createActionDedupesRepeatDays() {
        val task = taskPayload("create").put("repeat_days", JSONArray(listOf(0, 0, 2)))
        val result = DeepSeekClient.parseCommandResult(
            payloadWithActions(task), emptySet(), webSearchEnabled = false)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        val create = actions[0] as? AIAction.Create ?: return fail("expected create")
        assertEquals(listOf(0, 2), create.task.repeatDays)
    }

    @Test(expected = DeepSeekException::class)
    fun createActionRejectsOutOfRangeDuration() {
        val task = taskPayload("create").put("duration_minutes", 1441)
        DeepSeekClient.parseCommandResult(
            payloadWithActions(task), emptySet(), webSearchEnabled = false)
    }

    @Test(expected = DeepSeekException::class)
    fun createActionRejectsInvalidRepeatTimeRange() {
        val task = taskPayload("create").put("repeat_times", JSONArray(listOf("99:99")))
        DeepSeekClient.parseCommandResult(
            payloadWithActions(task), emptySet(), webSearchEnabled = false)
    }

    @Test(expected = DeepSeekException::class)
    fun updateActionRequiresValidUuid() {
        val payload = payloadWithActions(taskPayload("update", uuid = "missing"))
        DeepSeekClient.parseCommandResult(payload, setOf("a"), webSearchEnabled = false)
    }

    @Test
    fun completeAction() {
        val payload = payloadWithActions(JSONObject().put("action", "complete").put("uuid", "a"))
        val result = DeepSeekClient.parseCommandResult(payload, setOf("a"), webSearchEnabled = false)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(AIAction.Complete("a"), actions[0])
    }

    @Test(expected = DeepSeekException::class)
    fun deleteActionInvalidUuidThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "delete").put("uuid", "missing"))
        DeepSeekClient.parseCommandResult(payload, setOf("a"), webSearchEnabled = false)
    }

    @Test
    fun clarifyPassthrough() {
        val payload = JSONObject()
            .put("question", "什么时候提醒你交材料?")
            .put("options", JSONArray(listOf("明天 09:00", "明天 14:00")))
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
        val clarify = result as? AICommandResult.Clarify ?: return fail("expected clarify")
        assertEquals("什么时候提醒你交材料?", clarify.question)
        assertEquals(listOf("明天 09:00", "明天 14:00"), clarify.options)
    }

    @Test(expected = DeepSeekException::class)
    fun missingActionsThrows() {
        DeepSeekClient.parseCommandResult(JSONObject(), emptySet(), webSearchEnabled = false)
    }

    @Test(expected = DeepSeekException::class)
    fun unknownActionThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "unknown"))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
    }

    // ---- ReAct 工具调用(web_search)----

    @Test
    fun toolCallWebSearch() {
        val payload = JSONObject()
            .put("thought", "需要查最新价格")
            .put("tool", "web_search")
            .put("query", "iPhone 17 Pro 价格")
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
        val toolCall = result as? AICommandResult.ToolCall ?: return fail("expected toolCall")
        assertEquals("需要查最新价格", toolCall.thought)
        assertEquals("iPhone 17 Pro 价格", (toolCall.tool as AITool.WebSearch).query)
    }

    @Test(expected = DeepSeekException::class)
    fun toolCallWebSearchMissingQueryThrows() {
        val payload = JSONObject().put("thought", "…").put("tool", "web_search")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
    }

    /** webSearchEnabled == false 时 prompt 里没提过这个选项,模型幻觉出来也不认,
     * 落到 actions 解析(这里没给 actions,按"缺少 actions"报错)。 */
    @Test(expected = DeepSeekException::class)
    fun toolCallIgnoredWhenWebSearchDisabled() {
        val payload = JSONObject().put("tool", "web_search").put("query", "x")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
    }

    // ---- ReAct 工具调用(web_fetch)----

    @Test
    fun toolCallWebFetch() {
        val payload = JSONObject()
            .put("thought", "用户给了链接,需要看内容")
            .put("tool", "web_fetch")
            .put("url", "https://example.com/article")
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
        val toolCall = result as? AICommandResult.ToolCall ?: return fail("expected toolCall")
        assertEquals("用户给了链接,需要看内容", toolCall.thought)
        assertEquals("https://example.com/article", (toolCall.tool as AITool.WebFetch).url)
    }

    @Test(expected = DeepSeekException::class)
    fun toolCallWebFetchMissingUrlThrows() {
        val payload = JSONObject().put("thought", "…").put("tool", "web_fetch")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
    }

    @Test(expected = DeepSeekException::class)
    fun toolCallIgnoredWhenWebFetchDisabled() {
        val payload = JSONObject().put("tool", "web_fetch").put("url", "https://example.com")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
    }

    // ---- answer 操作 ----

    @Test
    fun answerActionAlone() {
        val payload = payloadWithActions(JSONObject().put("action", "answer").put("text", "今天多云转晴"))
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.Answer("今天多云转晴"), actions[0])
    }

    @Test(expected = DeepSeekException::class)
    fun answerEmptyTextThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "answer").put("text", "  "))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
    }

    /** webSearchEnabled == false 时,即使模型幻觉出 answer,也按未知 action 处理。 */
    @Test(expected = DeepSeekException::class)
    fun answerWhenDisabledThrowsUnknownAction() {
        val payload = payloadWithActions(JSONObject().put("action", "answer").put("text", "今天多云转晴"))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false)
    }

    /** answer 与写操作混在一句话里返回时,丢弃 answer 只留写操作。 */
    @Test
    fun answerMixedWithCreateDropsAnswer() {
        val payload = payloadWithActions(
            taskPayload("create"),
            JSONObject().put("action", "answer").put("text", "顺带回答"),
        )
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertTrue(actions[0] is AIAction.Create)
    }

    /** 多条 answer 混在一起时只留第一条。 */
    @Test
    fun multipleAnswerCollapsesToFirst() {
        val payload = payloadWithActions(
            JSONObject().put("action", "answer").put("text", "回答一"),
            JSONObject().put("action", "answer").put("text", "回答二"),
        )
        val result = DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.Answer("回答一"), actions[0])
    }

    // ---- memorize(收藏)----

    @Test
    fun memorizeValidWhenEnabled() {
        val payload = payloadWithActions(
            JSONObject().put("action", "memorize").put("text", "wifi密码是8888"))
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.Memorize("wifi密码是8888"), actions[0])
    }

    @Test(expected = DeepSeekException::class)
    fun memorizeEmptyTextThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "memorize").put("text", "  "))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
    }

    /** memoryEnabled == false(如未开启记忆功能)时,即使模型幻觉出 memorize,
     * 也按未知 action 处理,保持旧行为。 */
    @Test(expected = DeepSeekException::class)
    fun memorizeWhenDisabledThrowsUnknownAction() {
        val payload = payloadWithActions(
            JSONObject().put("action", "memorize").put("text", "wifi密码是8888"))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = false)
    }

    /** 一句话里同时收藏 + 新建:两条操作都保留(memorize 不受归一化影响,
     * 和写操作可以并存)。 */
    @Test
    fun memorizeCoexistsWithCreate() {
        val payload = payloadWithActions(
            taskPayload("create"),
            JSONObject().put("action", "memorize").put("text", "门禁码1234"),
        )
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(2, actions.size)
    }

    // ---- suggest_memorize(AI 主动建议收藏)----

    @Test
    fun suggestMemorizeValidWhenEnabled() {
        val payload = payloadWithActions(
            JSONObject().put("action", "suggest_memorize").put("text", "周三下午一般没空"))
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.SuggestMemorize("周三下午一般没空"), actions[0])
    }

    @Test(expected = DeepSeekException::class)
    fun suggestMemorizeEmptyTextThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "suggest_memorize").put("text", "  "))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
    }

    @Test(expected = DeepSeekException::class)
    fun suggestMemorizeWhenDisabledThrowsUnknownAction() {
        val payload = payloadWithActions(
            JSONObject().put("action", "suggest_memorize").put("text", "周三下午一般没空"))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = false)
    }

    /** suggest_memorize 是信息类操作(和 ask_memory/answer 同一组),与写操作
     * 混在一句话里返回时应该被丢弃,不像 memorize 那样可以共存。 */
    @Test
    fun suggestMemorizeMixedWithCreateDropsSuggestion() {
        val payload = payloadWithActions(
            taskPayload("create"),
            JSONObject().put("action", "suggest_memorize").put("text", "周三下午一般没空"),
        )
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertTrue(actions[0] is AIAction.Create)
    }

    // ---- ask_memory(查记忆)+ 归一化兜底 ----

    @Test
    fun askMemoryAlone() {
        val payload = payloadWithActions(
            JSONObject().put("action", "ask_memory").put("question", "wifi密码是多少"))
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.AskMemory("wifi密码是多少"), actions[0])
    }

    @Test(expected = DeepSeekException::class)
    fun askMemoryEmptyQuestionThrows() {
        val payload = payloadWithActions(JSONObject().put("action", "ask_memory").put("question", ""))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
    }

    @Test(expected = DeepSeekException::class)
    fun askMemoryWhenDisabledThrowsUnknownAction() {
        val payload = payloadWithActions(
            JSONObject().put("action", "ask_memory").put("question", "wifi密码是多少"))
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = false)
    }

    /** 模型不守"ask_memory 单独出现"的规则、返回多条时只留第一条。 */
    @Test
    fun multipleAskMemoryCollapsesToFirst() {
        val payload = payloadWithActions(
            JSONObject().put("action", "ask_memory").put("question", "问题一"),
            JSONObject().put("action", "ask_memory").put("question", "问题二"),
        )
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertEquals(AIAction.AskMemory("问题一"), actions[0])
    }

    /** ask_memory 与写操作混在一句话里返回时,丢弃 ask_memory 只留写操作。 */
    @Test
    fun askMemoryMixedWithCreateDropsAskMemory() {
        val payload = payloadWithActions(
            taskPayload("create"),
            JSONObject().put("action", "ask_memory").put("question", "问题一"),
        )
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val actions = (result as? AICommandResult.Actions)?.actions ?: return fail("expected actions")
        assertEquals(1, actions.size)
        assertTrue(actions[0] is AIAction.Create)
    }

    // ---- ReAct 工具调用(search_memory)----

    @Test
    fun toolCallSearchMemory() {
        val payload = JSONObject()
            .put("thought", "需要先看看装备清单写了什么")
            .put("tool", "search_memory")
            .put("query", "爬山装备清单")
        val result = DeepSeekClient.parseCommandResult(
            payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
        val toolCall = result as? AICommandResult.ToolCall ?: return fail("expected toolCall")
        assertEquals("需要先看看装备清单写了什么", toolCall.thought)
        assertEquals("爬山装备清单", (toolCall.tool as AITool.SearchMemory).query)
    }

    @Test(expected = DeepSeekException::class)
    fun toolCallSearchMemoryMissingQueryThrows() {
        val payload = JSONObject().put("thought", "…").put("tool", "search_memory")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = true)
    }

    /** memoryEnabled == false 时 prompt 里根本没提过这个选项,模型幻觉出来也不认,
     * 落到 actions 解析(这里没给 actions,按"缺少 actions"报错)。 */
    @Test(expected = DeepSeekException::class)
    fun toolCallIgnoredWhenMemoryDisabled() {
        val payload = JSONObject().put("tool", "search_memory").put("query", "x")
        DeepSeekClient.parseCommandResult(payload, emptySet(), webSearchEnabled = false, memoryEnabled = false)
    }
}
