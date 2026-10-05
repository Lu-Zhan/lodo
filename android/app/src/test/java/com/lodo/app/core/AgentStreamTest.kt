package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 流式输出纯逻辑,同 iOS AgentStreamTests。 */
class AgentStreamTest {
    @Test
    fun parseLineDeltaUsageAndDone() {
        assertEquals(AgentStream.Event.Delta("你", null),
            AgentStream.parseLine("""data: {"choices":[{"delta":{"content":"你"}}]}"""))
        assertEquals(AgentStream.Event.Delta(null, "想"),
            AgentStream.parseLine("""data: {"choices":[{"delta":{"reasoning_content":"想"}}]}"""))
        // DeepSeek 把 usage 搭在最后一片空 delta 上:判据是有没有可显示的增量,不是 choices 空不空。
        assertEquals(AgentStream.Event.Usage(120, 30),
            AgentStream.parseLine("""data: {"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":30}}"""))
        assertEquals(AgentStream.Event.Done, AgentStream.parseLine("data: [DONE]"))
        assertNull(AgentStream.parseLine(": keep-alive"))
        assertNull(AgentStream.parseLine(""))
    }

    private fun feed(vararg pieces: String): Pair<AnswerStreamScanner, List<String>> {
        val s = AnswerStreamScanner()
        val out = pieces.mapNotNull { s.consume(it) }
        return s to out
    }

    @Test
    fun answerIsRevealedProgressively() {
        val (s, out) = feed("""{"actions": [{"action": "ans""", """wer", "text": "你好""", """,世界""", """"}]}""")
        assertEquals(listOf("你好", "你好,世界"), out)
        assertEquals("你好,世界", s.currentText)
    }

    @Test
    fun textBeforeActionIsBufferedUntilActionKnown() {
        val (_, out) = feed("""{"actions": [{"text": "先来的正文"""", """, "action": "answer"}]}""")
        assertEquals(listOf("先来的正文"), out)
    }

    @Test
    fun otherActionsNeverLeak() {
        val (s, out) = feed("""{"actions": [{"action": "memorize", "text": "门禁码 1234"}]}""")
        assertTrue(out.isEmpty())
        assertTrue(s.isRejected)
        val (s2, out2) = feed("""{"thought": "搜一下", "tool": "web_search", "query": "天气"}""")
        assertTrue(out2.isEmpty())
        assertFalse(s2.isRejected)
    }

    @Test
    fun halfEscapesAreHeldBack() {
        val (_, out) = feed("""{"actions": [{"action": "answer", "text": "第一行\""", """n第二行 \u4f""", """60好 \ud83d""", """\ude00"}]}""")
        assertEquals(listOf("第一行", "第一行\n第二行 ", "第一行\n第二行 你好 ", "第一行\n第二行 你好 😀"), out)
    }

    @Test
    fun nestedValuesAreSkipped() {
        val (_, out) = feed("""{"actions": [{"meta": {"a": [1, "x"]}, "action": "answer", "n": 3, "text": "ok"}]}""")
        assertEquals(listOf("ok"), out)
    }

    @Test
    fun throttle() {
        val t = StreamThrottle()
        assertTrue(t.shouldFlush("a", 0))
        assertFalse(t.shouldFlush("b", 50))
        assertTrue(t.shouldFlush("c", 90))
        assertTrue(t.shouldFlush("\n", 95))
    }
}
