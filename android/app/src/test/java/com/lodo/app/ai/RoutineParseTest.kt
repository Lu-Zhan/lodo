package com.lodo.app.ai

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class RoutineParseTest {
    @Test fun textAndTools() {
        assertEquals(DeepSeekClient.RoutineOutcome.Text("早上好"), DeepSeekClient.parseRoutine(JSONObject("""{"text": " 早上好 "}"""), true))
        assertEquals(DeepSeekClient.RoutineOutcome.Tool("查天气", "上海天气", null),
            DeepSeekClient.parseRoutine(JSONObject("""{"thought": "查天气", "tool": "web_search", "query": "上海天气"}"""), true))
        assertEquals(DeepSeekClient.RoutineOutcome.Tool("", null, "https://a.com"),
            DeepSeekClient.parseRoutine(JSONObject("""{"tool": "web_fetch", "url": "https://a.com"}"""), true))
    }

    @Test(expected = DeepSeekException::class)
    fun toolIgnoredWhenWebOffFallsToMissingText() {
        DeepSeekClient.parseRoutine(JSONObject("""{"tool": "web_search", "query": "x"}"""), false)
    }
}

class LoadSkillParseTest {
    private val payload = JSONObject("""{"thought": "要按周报格式", "tool": "load_skill", "name": "写周报"}""")

    @Test fun loadSkillOnlyWhenCatalogExists() {
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, loadSkill = true)
        assertEquals(AICommandResult.ToolCall("要按周报格式", AITool.LoadSkill("写周报")), r)
    }

    @Test(expected = DeepSeekException::class)
    fun loadSkillRejectedWithoutCatalog() {
        DeepSeekClient.parseCommandResult(payload, emptySet(), false, loadSkill = false)
    }
}
