package com.lodo.app.core

import org.json.JSONObject

/**
 * AI 回复流式输出的纯逻辑,移植自 iOS AgentStream / AnswerStreamScanner / StreamThrottle。
 * **协议没变**:仍然是一次 `{"actions": [...]}`,只是边收边显示;收完后交给同一套解析。
 */
object AgentStream {
    sealed interface Event {
        data class Delta(val content: String?, val reasoning: String?) : Event
        data class Usage(val input: Int?, val output: Int?) : Event
        data object Done : Event
    }

    /** 一行 SSE → 事件;注释/心跳行、看不懂的行返回 null。 */
    fun parseLine(line: String): Event? {
        val t = line.trim()
        if (t.isEmpty() || t.startsWith(":") || !t.startsWith("data:")) return null
        val payload = t.removePrefix("data:").trim()
        if (payload == "[DONE]") return Event.Done
        val root = runCatching { JSONObject(payload) }.getOrNull() ?: return null
        val delta = root.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("delta")
        fun str(key: String) = delta?.takeIf { it.has(key) && !it.isNull(key) }?.optString(key)
        val content = str("content")
        // reasoning_content 是 DeepSeek 的字段名,reasoning 是另一些兼容服务商的。
        val reasoning = str("reasoning_content") ?: str("reasoning")
        // 空串不算增量:DeepSeek 把 usage 搭在一片空 delta 上,判据是"有没有可显示的增量"。
        if (!content.isNullOrEmpty() || !reasoning.isNullOrEmpty()) return Event.Delta(content, reasoning)
        root.optJSONObject("usage")?.let { u ->
            val input = if (u.has("prompt_tokens")) u.optInt("prompt_tokens") else null
            val output = if (u.has("completion_tokens")) u.optInt("completion_tokens") else null
            if (input != null || output != null) return Event.Usage(input, output)
        }
        return null
    }
}

/**
 * 容错扫描还没收完的 JSON,抽出第一个操作的 `answer` 正文(同 iOS AnswerStreamScanner)。
 * **按 action 的值门控**,不是只扫 "text" 键:memorize 之类的 payload 里也有 text,
 * 只扫键会把收藏正文先流进气泡。三态:action 还没露面先缓冲 → 确认是 answer 才吐 → 别的动作永久闭嘴。
 * 转义序列收到一半时停在反斜杠前面,绝不吐半个。
 */
class AnswerStreamScanner {
    private val raw = StringBuilder()
    var currentText = ""
        private set
    var isRejected = false
        private set

    /** 喂一片增量;有新的可显示全文时返回全文,否则 null。 */
    fun consume(delta: String): String? {
        if (isRejected) return null
        raw.append(delta)
        val r = scanFirstAction(raw.toString()) ?: return null
        if (r.action != null && r.action != "answer") {
            isRejected = true
            currentText = ""
            return null
        }
        val text = r.text
        if (r.action != "answer" || text == null || text == currentText) return null
        currentText = text
        return text
    }

    data class FirstAction(val action: String?, val text: String?)

    companion object {
        fun scanFirstAction(raw: String): FirstAction? {
            val keyAt = raw.indexOf("\"actions\"").takeIf { it >= 0 } ?: return null
            var i = keyAt + "\"actions\"".length
            val bracket = raw.indexOf('[', i).takeIf { it >= 0 } ?: return null
            i = bracket + 1
            val brace = raw.indexOf('{', i).takeIf { it >= 0 } ?: return null
            i = brace + 1
            var action: String? = null
            var text: String? = null
            fun ws() { while (i < raw.length && raw[i] in " \n\r\t") i++ }
            while (i < raw.length) {
                ws(); if (i >= raw.length) break
                if (raw[i] == '}' || raw[i] != '"') break
                val key = readString(raw, i) ?: break
                if (!key.closed) break
                i = key.end; ws()
                if (i >= raw.length || raw[i] != ':') break
                i++; ws(); if (i >= raw.length) break
                when (raw[i]) {
                    '"' -> {
                        val v = readString(raw, i) ?: break
                        if (key.value == "action") { if (v.closed) action = v.value }
                        else if (key.value == "text") text = v.value
                        if (!v.closed) break
                        i = v.end
                    }
                    '{', '[' -> i = skipContainer(raw, i) ?: break
                    else -> while (i < raw.length && raw[i] != ',' && raw[i] != '}') i++
                }
                ws(); if (i >= raw.length) break
                if (raw[i] == ',') { i++; continue }
                break
            }
            return FirstAction(action, text)
        }

        private fun skipContainer(s: String, from: Int): Int? {
            var depth = 0; var inStr = false; var esc = false; var i = from
            while (i < s.length) {
                val c = s[i]
                if (inStr) { if (esc) esc = false else if (c == '\\') esc = true else if (c == '"') inStr = false }
                else if (c == '"') inStr = true
                else if (c == '{' || c == '[') depth++
                else if (c == '}' || c == ']') { depth--; if (depth == 0) return i + 1 }
                i++
            }
            return null
        }

        data class Scanned(val value: String, val closed: Boolean, val end: Int)

        private fun readString(s: String, start: Int): Scanned? {
            if (start >= s.length || s[start] != '"') return null
            val out = StringBuilder()
            var i = start + 1
            while (i < s.length) {
                val c = s[i]
                if (c == '"') return Scanned(out.toString(), true, i + 1)
                if (c != '\\') { out.append(c); i++; continue }
                if (i + 1 >= s.length) return Scanned(out.toString(), false, i)
                val next = s[i + 1]
                if (next == 'u') {
                    val hi = hex(s, i) ?: return Scanned(out.toString(), false, i)
                    if (hi in 0xD800..0xDBFF) {
                        // 高位代理项:必须等到配对的低位。
                        val lo = hex(s, i + 6)?.takeIf { it in 0xDC00..0xDFFF } ?: return Scanned(out.toString(), false, i)
                        out.appendCodePoint(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)); i += 12
                    } else { out.append(hi.toChar()); i += 6 }
                    continue
                }
                out.append(when (next) { 'n' -> '\n'; 't' -> '\t'; 'r' -> '\r'; 'b' -> '\b'; 'f' -> '\u000C'; else -> next })
                i += 2
            }
            return Scanned(out.toString(), false, i)
        }

        private fun hex(s: String, at: Int): Int? {
            if (at + 5 >= s.length || s[at] != '\\' || s[at + 1] != 'u') return null
            return s.substring(at + 2, at + 6).toIntOrNull(16)
        }
    }
}

/** 80ms 或遇到换行才刷新一次界面(同 iOS StreamThrottle);时间由调用方传入,便于单测。 */
class StreamThrottle(private val intervalMillis: Long = 80) {
    private var last: Long? = null

    fun shouldFlush(delta: String, now: Long = System.currentTimeMillis()): Boolean {
        if (delta.contains("\n") || delta.contains("\\n")) { last = now; return true }
        val l = last
        if (l == null || now - l >= intervalMillis) { last = now; return true }
        return false
    }
}
