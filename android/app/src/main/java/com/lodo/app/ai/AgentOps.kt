package com.lodo.app.ai

import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Strings
import com.lodo.app.core.TravelItemKind
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/*
 * command 协议里这一轮从 iOS 移植过来的新操作:提问卡(ask)、倒数日、资产台账、订阅、
 * 行程规划/调整。解析函数都是纯函数(给 JSON、不发请求),和 iOS 的同名 parse* 同义。
 */

private fun parseError(detail: String): DeepSeekException =
    DeepSeekException(Strings.translate("无法解析:", CurrentLang.value) + detail)

internal fun JSONObject.text(key: String): String? =
    optString(key).trim().takeIf { has(key) && !isNull(key) && it.isNotEmpty() }

internal fun JSONObject.number(key: String): Double? {
    if (!has(key) || isNull(key)) return null
    return when (val v = opt(key)) {
        is Number -> v.toDouble()
        // "3,200"、"¥3200"、"3200 元" 这类带符号/千分位/单位的也认(同 iOS planPrice)。
        is String -> v.filter { it.isDigit() || it == '.' || it == '-' }.toDoubleOrNull()
        else -> null
    }
}

internal fun JSONObject.bool(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return when (val v = opt(key)) {
        is Boolean -> v
        is String -> v.lowercase() in setOf("true", "yes", "1")
        is Number -> v.toInt() != 0
        else -> null
    }
}

/** 把模型抄回来的 id 对回列表里原样的字符串(忽略大小写/空白/花括号/[id:…] 外壳),同 iOS canonicalID。 */
fun canonicalId(given: String, valid: Collection<String>): String? {
    var key = given.trim()
    if (key.startsWith("[id:") && key.endsWith("]")) key = key.drop(4).dropLast(1)
    if (key.startsWith("id:")) key = key.drop(3)
    key = key.trim('{', '}', ' ')
    if (key in valid) return key
    return valid.firstOrNull { it.equals(key, ignoreCase = true) }
}

/** delete_memory 的 ids(同 iOS DeepSeekClient.parseMemoryIDs):认 "ids" 数组或单个 "id",
 * 去 [id:…] 外壳和花括号,只留合法 uuid(统一成小写,同 UUID.toString())并去重;
 * 一个都没有时报错——模型拿标题当 id 时不能静默变成"什么都没删"。 */
fun parseMemoryIds(raw: JSONObject): List<String> {
    val given = mutableListOf<String>()
    raw.optJSONArray("ids")?.let { arr -> for (i in 0 until arr.length()) arr.optString(i).let(given::add) }
    raw.optString("id").takeIf { it.isNotEmpty() }?.let(given::add)
    val ids = given.mapNotNull { value ->
        var key = value.trim()
        if (key.startsWith("[id:") && key.endsWith("]")) key = key.drop(4).dropLast(1)
        if (key.startsWith("id:")) key = key.drop(3)
        key = key.trim('{', '}', ' ')
        runCatching { java.util.UUID.fromString(key) }.getOrNull()
            ?.toString()?.takeIf { it.equals(key, ignoreCase = true) }
    }.distinct()
    if (ids.isEmpty()) {
        throw DeepSeekException(Strings.translate("无法解析:返回格式异常:delete_memory 缺少有效的记忆 id", CurrentLang.value))
    }
    return ids
}

private val dateTimeFmt = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
private val dateFmt = DateTimeFormatter.ofPattern("yyyy-MM-dd")

/** "yyyy-MM-dd" 或 "yyyy-MM-dd HH:mm"。 */
fun parsePlanDate(text: String?): LocalDateTime? {
    val s = text?.trim() ?: return null
    runCatching { return LocalDateTime.parse(s, dateTimeFmt) }
    runCatching { return LocalDate.parse(s.take(10), dateFmt).atStartOfDay() }
    return null
}

// ---------------- 提问卡 ----------------

data class AskOption(val label: String, val description: String = "", val recommended: Boolean = false)
data class AskQuestion(val header: String, val question: String, val multiSelect: Boolean, val options: List<AskOption>)

/** 反问载荷 → 题目列表:最多 4 题、每题最多 6 个选项,空题丢弃,全丢光才报错(同 iOS parseAsk)。 */
fun parseAsk(raw: JSONArray): List<AskQuestion> {
    val questions = mutableListOf<AskQuestion>()
    for (i in 0 until minOf(raw.length(), 4)) {
        val q = raw.optJSONObject(i) ?: continue
        val text = q.text("question") ?: continue
        val opts = q.optJSONArray("options") ?: JSONArray()
        val options = (0 until minOf(opts.length(), 6)).mapNotNull { j ->
            when (val o = opts.opt(j)) {
                is JSONObject -> o.text("label")?.let {
                    AskOption(it, o.optString("description"), o.optBoolean("recommended", false))
                }
                is String -> o.trim().takeIf { it.isNotEmpty() }?.let { AskOption(it) }
                else -> null
            }
        }
        if (options.isEmpty()) continue
        questions += AskQuestion(q.text("header") ?: "", text, q.optBoolean("multi_select", false), options)
    }
    if (questions.isEmpty()) throw parseError("返回格式异常:提问没有内容")
    return questions
}

fun AskQuestion.toJson(): JSONObject = JSONObject().put("header", header).put("question", question)
    .put("multi_select", multiSelect)
    .put("options", JSONArray().apply {
        options.forEach { put(JSONObject().put("label", it.label).put("description", it.description).put("recommended", it.recommended)) }
    })

// ---------------- 倒数日 ----------------

data class CountdownDraft(
    val title: String, val start: LocalDateTime, val end: LocalDateTime? = null, val allDay: Boolean = true,
    val startReminders: List<Int> = emptyList(), val endReminders: List<Int> = emptyList(),
    val showInWidget: Boolean? = null, val notes: String = "",
)

data class CountdownChange(
    val title: String? = null, val start: LocalDateTime? = null,
    /** null = 不动;clearEnd = true 时去掉结束时间。 */
    val end: LocalDateTime? = null, val clearEnd: Boolean = false,
    val allDay: Boolean? = null, val startReminders: List<Int>? = null, val endReminders: List<Int>? = null,
    val showInWidget: Boolean? = null, val notes: String? = null, val archived: Boolean? = null,
) {
    val isEmpty get() = this == CountdownChange()
}

sealed interface CountdownOp {
    data class Create(val draft: CountdownDraft) : CountdownOp
    data class Update(val id: String, val change: CountdownChange) : CountdownOp
    data class Delete(val id: String) : CountdownOp
}

fun parseCountdownOp(raw: JSONObject, action: String, validIds: Collection<String>): CountdownOp {
    fun reminders(key: String): List<Int>? {
        val arr = raw.optJSONArray(key) ?: return null
        return (0 until arr.length()).mapNotNull {
            when (val v = arr.opt(it)) {
                is Number -> v.toInt()
                is String -> v.trim().toIntOrNull()
                else -> null
            }
        }.filter { it >= 0 }.toSortedSet().take(6)
    }
    fun id(): String = canonicalId(raw.text("id") ?: "", validIds) ?: throw parseError("找不到要操作的倒数日")
    return when (action) {
        "create_countdown" -> {
            val title = raw.text("title") ?: throw parseError("返回格式异常:倒数日缺少名称")
            val startText = raw.text("start") ?: throw parseError("返回格式异常:倒数日缺少日期")
            val start = parsePlanDate(startText) ?: throw parseError("返回格式异常:倒数日缺少日期")
            val allDay = raw.bool("all_day") ?: !startText.contains(":")
            var end = parsePlanDate(raw.text("end"))
            if (end != null && end.isBefore(start)) end = null
            CountdownOp.Create(
                CountdownDraft(
                    title, start, end, allDay, reminders("start_reminders") ?: emptyList(),
                    if (end == null) emptyList() else reminders("end_reminders") ?: emptyList(),
                    raw.bool("show_in_widget"), raw.text("notes") ?: "",
                )
            )
        }
        "update_countdown" -> {
            val target = id()
            val endRaw = raw.opt("end")
            val clear = raw.has("end") && (raw.isNull("end") || (endRaw is String && endRaw.isBlank()))
            val change = CountdownChange(
                title = raw.text("title"), start = parsePlanDate(raw.text("start")),
                end = if (clear) null else parsePlanDate(raw.text("end")), clearEnd = clear,
                allDay = raw.bool("all_day"), startReminders = reminders("start_reminders"),
                endReminders = reminders("end_reminders"), showInWidget = raw.bool("show_in_widget"),
                notes = if (raw.has("notes") && !raw.isNull("notes")) raw.optString("notes") else null,
                archived = raw.bool("archived"),
            )
            if (change.isEmpty) throw parseError("返回格式异常:倒数日没有要改的内容")
            CountdownOp.Update(target, change)
        }
        else -> CountdownOp.Delete(id())
    }
}

// ---------------- 资产 / 订阅 ----------------

data class AssetDraft(
    val title: String, val category: String = "", val value: Double? = null, val currency: String = "CNY",
    val liability: Double? = null, val interestRate: Double? = null, val note: String = "",
)

data class AssetChange(
    val title: String? = null, val category: String? = null, val value: Double? = null, val currency: String? = null,
    val liability: Double? = null, val interestRate: Double? = null, val note: String? = null,
) {
    val isEmpty get() = this == AssetChange()
}

sealed interface AssetOp {
    data class Create(val draft: AssetDraft) : AssetOp
    data class Update(val id: String, val change: AssetChange) : AssetOp
}

fun parseAssetOp(raw: JSONObject, action: String, validIds: Collection<String>): AssetOp {
    val currency = raw.text("currency")?.uppercase()
    if (action == "create_asset") {
        val title = raw.text("title") ?: throw parseError("返回格式异常:资产缺少名称")
        val value = raw.number("value")
        val liability = raw.number("liability")
        if (value == null && liability == null) throw parseError("返回格式异常:资产缺少金额")
        return AssetOp.Create(
            AssetDraft(title, raw.text("category") ?: "", value, currency ?: "CNY", liability,
                raw.number("interest_rate"), raw.text("note") ?: "")
        )
    }
    val id = canonicalId(raw.text("id") ?: "", validIds) ?: throw parseError("找不到要修改的资产")
    val change = AssetChange(
        raw.text("title"), raw.text("category"), raw.number("value"), currency, raw.number("liability"),
        raw.number("interest_rate"), if (raw.has("note") && !raw.isNull("note")) raw.optString("note") else null,
    )
    if (change.isEmpty) throw parseError("返回格式异常:资产没有要改的内容")
    return AssetOp.Update(id, change)
}

data class FeedDraft(val url: String?, val name: String?, val kind: String = "news") {
    val label get() = name ?: url ?: ""
}

data class FeedChange(val title: String? = null, val kind: String? = null, val enabled: Boolean? = null) {
    val isEmpty get() = this == FeedChange()
}

sealed interface FeedOp {
    data class Subscribe(val draft: FeedDraft) : FeedOp
    data class Update(val id: String, val change: FeedChange) : FeedOp
}

fun parseFeedOps(raw: JSONObject, action: String, validIds: Collection<String>): List<FeedOp> {
    fun kind(o: JSONObject) = o.text("kind")?.lowercase()?.takeIf { it == "news" || it == "blog" }
    if (action == "subscribe_feed") {
        val arr = raw.optJSONArray("feeds")
        val items = if (arr != null) (0 until arr.length()).mapNotNull { arr.optJSONObject(it) } else listOf(raw)
        val seen = mutableSetOf<String>()
        val drafts = items.mapNotNull { item ->
            val url = item.text("url")
            val name = item.text("name") ?: item.text("title")
            if (url == null && name == null) return@mapNotNull null
            if (!seen.add((url ?: name ?: "").lowercase())) return@mapNotNull null
            FeedDraft(url, name, kind(item) ?: kind(raw) ?: "news")
        }
        if (drafts.isEmpty()) throw parseError("返回格式异常:订阅缺少链接或名称")
        return drafts.take(20).map { FeedOp.Subscribe(it) }
    }
    val id = canonicalId(raw.text("id") ?: "", validIds) ?: throw parseError("找不到要修改的订阅")
    val change = FeedChange(raw.text("title"), kind(raw), raw.bool("enabled"))
    if (change.isEmpty) throw parseError("返回格式异常:订阅没有要改的内容")
    return listOf(FeedOp.Update(id, change))
}

/** 按名字模糊找订阅源,同 iOS FeedMatch。 */
object FeedMatch {
    fun normalize(text: String) = text.lowercase().filter { it.isLetterOrDigit() }

    fun score(query: String, title: String, url: String): Int {
        val q = normalize(query)
        if (q.isEmpty()) return 0
        val t = normalize(title)
        if (q == t) return 100
        if (t.isNotEmpty() && (t.contains(q) || q.contains(t))) {
            val ratio = minOf(q.length, t.length).toDouble() / maxOf(q.length, t.length)
            return if (ratio >= 0.3) 50 + (ratio * 40).toInt() else 0
        }
        val host = normalize(runCatching { java.net.URI(url).host }.getOrNull() ?: url)
        if (q.length >= 3 && host.contains(q)) return 40
        return 0
    }

    fun <T> best(query: String, candidates: List<T>, title: (T) -> String, url: (T) -> String): T? =
        candidates.map { it to score(query, title(it), url(it)) }.filter { it.second > 0 }
            .maxByOrNull { it.second }?.first
}

// ---------------- 行程规划 / 调整 ----------------

data class TripPlanItem(
    val kind: TravelItemKind, val title: String, val note: String = "",
    val start: LocalDateTime? = null, val end: LocalDateTime? = null, val placeName: String? = null,
    val price: Double? = null, val currency: String? = null, val code: String? = null,
)

data class TripPlanProposal(
    val tripTitle: String, val startDate: LocalDate, val endDate: LocalDate, val summary: String,
    val items: List<TripPlanItem>, val city: String? = null, val country: String? = null,
    val recorded: Boolean = false,
)

private fun parsePlanItem(o: JSONObject): TripPlanItem? {
    val kind = TravelItemKind.from(o.text("kind")) ?: return null
    val title = o.text("title") ?: return null
    val start = parsePlanDate(o.text("start"))
    var end = parsePlanDate(o.text("end"))
    if (start != null && end != null && end.isBefore(start)) end = null
    return TripPlanItem(kind, title, o.text("note") ?: "", start, end, o.text("place"), o.number("price"),
        o.text("currency")?.uppercase(), o.text("code"))
}

/** plan_trip → 规划;规划(非记录)的整份落在今天之前时按整年往后挪(同 iOS parseTripPlan(now:))。 */
fun parseTripPlan(raw: JSONObject, now: LocalDateTime = LocalDateTime.now()): TripPlanProposal {
    val arr = raw.optJSONArray("items") ?: JSONArray()
    val items = (0 until minOf(arr.length(), 60)).mapNotNull { arr.optJSONObject(it)?.let(::parsePlanItem) }
    if (items.isEmpty()) throw parseError("返回格式异常:行程规划没有任何安排")
    val starts = items.mapNotNull { it.start }
    val ends = items.mapNotNull { it.end ?: it.start }
    var start = parsePlanDate(raw.text("start_date"))?.toLocalDate() ?: starts.minOrNull()?.toLocalDate()
    var end = parsePlanDate(raw.text("end_date"))?.toLocalDate() ?: (ends.maxOrNull() ?: starts.maxOrNull())?.toLocalDate()
    if (start == null || end == null) throw parseError("返回格式异常:行程规划缺少日期")
    if (end.isBefore(start)) { val t = start; start = end; end = t }
    val recorded = raw.optBoolean("record", false)
    var planned = items
    if (!recorded) {
        val today = now.toLocalDate()
        var years = 0
        while (years < 3 && end!!.plusYears(years.toLong()).isBefore(today)) years++
        if (years > 0) {
            val y = years.toLong()
            start = start!!.plusYears(y)
            end = end!!.plusYears(y)
            planned = items.map { it.copy(start = it.start?.plusYears(y), end = it.end?.plusYears(y)) }
        }
    }
    return TripPlanProposal(raw.text("trip") ?: "旅行规划", start!!, end!!, raw.text("summary") ?: "", planned,
        raw.text("city"), raw.text("country"), recorded)
}

data class TripEditUpdate(
    val id: String, val title: String? = null, val note: String? = null,
    val start: LocalDateTime? = null, val end: LocalDateTime? = null, val placeName: String? = null,
    /** 费用:给已经记下的行程项补/改花了多少钱(同 iOS TripEditUpdate.price/currency)。 */
    val price: Double? = null, val currency: String? = null,
) {
    val isEmpty get() = title == null && note == null && start == null && end == null && placeName == null &&
        price == null && currency == null

    /** 只补/改费用和备注。航班允许这一种改法:时刻座位来自订单,但"机票花了 3200"该记得上。 */
    val touchesOnlyCostOrNote get() = title == null && start == null && end == null && placeName == null
}

data class TripEdit(
    val tripTitle: String, val summary: String, val removeIds: List<String>,
    val additions: List<TripPlanItem>, val updates: List<TripEditUpdate>,
)

/** edit_trip → 调整:认 [id: 前缀、去重、既删又改以删为准,一样都没有才报错(同 iOS parseTripEdit)。 */
fun parseTripEdit(raw: JSONObject): TripEdit {
    fun clean(s: String): String {
        var t = s.trim()
        if (t.startsWith("[id:")) t = t.drop(4)
        if (t.startsWith("id:")) t = t.drop(3)
        if (t.endsWith("]")) t = t.dropLast(1)
        return t.trim()
    }
    val removeIds = mutableListOf<String>()
    raw.optJSONArray("remove")?.let { arr ->
        for (i in 0 until arr.length()) {
            val id = clean(arr.optString(i))
            if (id.isNotEmpty() && id !in removeIds) removeIds += id
        }
    }
    val addArr = raw.optJSONArray("add") ?: JSONArray()
    val additions = (0 until minOf(addArr.length(), 30)).mapNotNull { addArr.optJSONObject(it)?.let(::parsePlanItem) }
    val updArr = raw.optJSONArray("update") ?: JSONArray()
    val updates = (0 until updArr.length()).mapNotNull { i ->
        val o = updArr.optJSONObject(i) ?: return@mapNotNull null
        val id = o.text("id")?.let(::clean) ?: return@mapNotNull null
        val start = parsePlanDate(o.text("start"))
        var end = parsePlanDate(o.text("end"))
        if (start != null && end != null && end.isBefore(start)) end = null
        TripEditUpdate(id, o.text("title"), o.text("note"), start, end, o.text("place"),
            o.number("price")?.takeIf { it >= 0 }, o.text("currency")?.uppercase()).takeIf { !it.isEmpty }
    }.filter { it.id !in removeIds }
    if (removeIds.isEmpty() && additions.isEmpty() && updates.isEmpty()) throw parseError("返回格式异常:行程调整没有任何改动")
    return TripEdit(raw.text("trip") ?: "", raw.text("summary") ?: "", removeIds, additions, updates)
}
