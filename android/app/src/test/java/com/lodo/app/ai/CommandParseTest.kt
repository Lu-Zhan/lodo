package com.lodo.app.ai

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** DeepSeekClient.parseCommandResult 离线单测(不发网络请求),1:1 移植自
 * ios/LodoCore/Tests/LodoCoreTests/CommandParseTests.swift 里和 Android 已对齐
 * 的部分(create/update/complete/delete/answer/web_search);Android 没有
 * memorize/ask_memory,不移植那部分。 */
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
}
