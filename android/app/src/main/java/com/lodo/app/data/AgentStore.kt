package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.AIConfig
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.TripPlanItem
import com.lodo.app.ai.TripPlanProposal
import com.lodo.app.core.TravelItemKind
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

/** AI 对话消息的种类(决定气泡怎么画),存储字符串别改。 */
object AgentKind {
    const val USER = "user"
    const val TEXT = "text"
    const val ANSWER = "answer"
    const val ERROR = "error"
    const val CONFIRM = "confirm"
    const val TASK_RESULT = "taskResult"
    const val BATCH_RESULT = "batchResult"
    const val MEMORY_RESULT = "memoryResult"
    const val SUGGEST_MEMORIZE = "suggestMemorize"
    const val ASK = "ask"
    const val COUNTDOWN_EDIT = "countdownEdit"
    const val LIBRARY_EDIT = "libraryEdit"
    const val TRIP_PLAN = "tripPlan"
    const val TRIP_EDIT = "tripEdit"
}

fun TripPlanProposal.toJson(): JSONObject = JSONObject().put("trip", tripTitle)
    .put("start", startDate.toString()).put("end", endDate.toString()).put("summary", summary)
    .put("city", city ?: "").put("country", country ?: "").put("recorded", recorded)
    .put("items", JSONArray(items.map {
        JSONObject().put("kind", it.kind.raw).put("title", it.title).put("note", it.note)
            .put("start", it.start?.toEpochMillis() ?: JSONObject.NULL).put("end", it.end?.toEpochMillis() ?: JSONObject.NULL)
            .put("place", it.placeName ?: "").put("price", it.price ?: JSONObject.NULL)
            .put("currency", it.currency ?: "").put("code", it.code ?: "")
    }))

fun tripPlanFromJson(o: JSONObject): TripPlanProposal {
    val arr = o.optJSONArray("items") ?: JSONArray()
    val items = (0 until arr.length()).mapNotNull { i ->
        val it = arr.getJSONObject(i)
        TripPlanItem(
            TravelItemKind.from(it.optString("kind")) ?: return@mapNotNull null, it.optString("title"), it.optString("note"),
            it.lng("start")?.toLocalDateTime(), it.lng("end")?.toLocalDateTime(), it.optString("place").ifBlank { null },
            it.dbl("price"), it.optString("currency").ifBlank { null }, it.optString("code").ifBlank { null },
        )
    }
    return TripPlanProposal(o.optString("trip"), LocalDate.parse(o.getString("start")), LocalDate.parse(o.getString("end")),
        o.optString("summary"), items, o.optString("city").ifBlank { null }, o.optString("country").ifBlank { null },
        o.optBoolean("recorded"))
}

/**
 * AI 助手的持久化:单一持续对话(消息表)、长期偏好(agent-preferences.md)、更早对话的
 * 滚动摘要(agent-summary.json)。对应 iOS AgentMessage / AgentPreferences / AgentConversationSummary。
 */
class AgentStore(private val context: Context, private val db: LodoDatabase) {
    private val dao get() = db.agentMessageDao()

    fun observeRecent(limit: Int) = dao.observeRecent(limit)
    suspend fun byUuid(uuid: String) = dao.byUuid(uuid)

    suspend fun insert(role: String, kind: String, content: String, payload: JSONObject? = null): AgentMessageEntity {
        // 同一毫秒连插两条时保证先后顺序。
        val last = dao.recent(1).firstOrNull()?.createdAtMillis ?: 0
        val msg = AgentMessageEntity(role = role, kind = kind, content = content, payloadJson = payload?.toString(),
            createdAtMillis = maxOf(System.currentTimeMillis(), last + 1))
        dao.upsert(msg)
        return msg
    }

    suspend fun update(msg: AgentMessageEntity) = dao.upsert(msg)
    suspend fun delete(uuid: String) = dao.delete(uuid)

    suspend fun clear() {
        dao.clear()
        summaryFile.delete()
    }

    /** 最近 limit 条(正序)。 */
    suspend fun recent(limit: Int) = dao.recent(limit).reversed()

    /** 最新一条:确认/撤销这类依赖上下文的按钮只在最新一条可点。 */
    suspend fun latest() = dao.recent(1).firstOrNull()

    /** 历史:最近 16 条逐条回传(content 是纯文字版)。 */
    suspend fun history(excludingUuid: String? = null): List<Pair<String, String>> =
        recent(17).filter { it.uuid != excludingUuid && it.kind != AgentKind.ERROR }.takeLast(16)
            .map { it.role to it.content.take(1200) }

    // ---- 偏好 ----

    private val prefsFile get() = File(context.filesDir, "agent-preferences.md")

    fun preferences(): String? = prefsFile.takeIf { it.exists() }?.readText()?.takeIf { it.isNotBlank() }

    fun savePreferences(text: String) {
        if (text.isBlank()) prefsFile.delete() else prefsFile.writeText(text.trim() + "\n")
    }

    /** 一行一条;互相包含即算重复(同 iOS AgentPreferences.append)。超 40 条让 AI 归纳。 */
    suspend fun appendPreference(text: String, config: AIConfig) {
        val line = text.trim().removePrefix("- ").trim()
        if (line.isEmpty()) return
        val lines = preferences()?.lines()?.map { it.removePrefix("- ").trim() }?.filter { it.isNotEmpty() }?.toMutableList() ?: mutableListOf()
        val dup = lines.indexOfFirst { it.contains(line) || line.contains(it) }
        if (dup >= 0) {
            if (line.length > lines[dup].length) lines[dup] = line else return
        } else lines += line
        savePreferences(lines.joinToString("\n") { "- $it" })
        if (lines.size > 40) runCatching {
            val merged = DeepSeekClient.consolidatePreferences(config, lines.joinToString("\n"))
            if (merged.isNotBlank()) savePreferences(merged.lines().filter { it.isNotBlank() }.joinToString("\n") { "- " + it.removePrefix("- ") })
        }
    }

    // ---- 更早对话的摘要 ----

    private val summaryFile get() = File(context.filesDir, "agent-summary.json")

    data class Summary(val text: String, val watermarkMillis: Long)

    fun summary(): Summary? = runCatching {
        val o = JSONObject(summaryFile.readText())
        Summary(o.getString("summary"), o.getLong("watermark"))
    }.getOrNull()

    fun resetSummary() { summaryFile.delete() }

    /** 窗口(最近 16 条)之外积够 20 条就压成一段常驻摘要;失败静默跳过、水位线不动(同 iOS)。 */
    suspend fun compactIfNeeded(config: AIConfig) {
        val current = summary()
        val all = recent(400)
        if (all.size <= 16) return
        val outside = all.dropLast(16).filter { it.createdAtMillis > (current?.watermarkMillis ?: 0) && it.kind != AgentKind.ERROR }
        if (outside.size < 20) return
        val transcript = outside.joinToString("\n") { (if (it.role == "user") "用户" else "助手") + ":" + it.content.take(600) }
        runCatching {
            val text = DeepSeekClient.summarizeConversation(config, current?.text, transcript)
            summaryFile.writeText(JSONObject().put("summary", text).put("watermark", outside.last().createdAtMillis).toString())
        }
    }
}
