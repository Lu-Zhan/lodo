package com.lodo.app.data

import com.lodo.app.ai.AssetOp
import com.lodo.app.ai.FeedOp
import com.lodo.app.core.AssetCategory
import com.lodo.app.ui.L
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** 一次资产/订阅操作的记录(卡片列出改了什么,撤销也靠它),同 iOS LibraryEditRecord。 */
data class LibraryEditRecord(
    val lines: List<Line> = emptyList(),
    val assetsBefore: List<MemoryEntity> = emptyList(),
    val feedsBefore: List<NewsFeedEntity> = emptyList(),
    val skipped: List<String> = emptyList(),
    val reverted: Boolean = false,
) {
    /** domain: asset / feed */
    data class Line(val domain: String, val created: Boolean, val uuid: String, val title: String, val detail: String)

    val hasChanges get() = lines.isNotEmpty()

    val transcript: String
        get() {
            fun part(domain: String, created: Boolean, prefix: String): String? {
                val t = lines.filter { it.domain == domain && it.created == created }.map { "「${it.title}」" + it.detail }
                return if (t.isEmpty()) null else prefix + t.joinToString("、")
            }
            val parts = listOfNotNull(part("asset", true, "新增资产:"), part("asset", false, "修改资产:"),
                part("feed", true, "新增订阅:"), part("feed", false, "修改订阅:")).toMutableList()
            if (skipped.isNotEmpty()) parts += "没做成:" + skipped.joinToString("、")
            if (reverted) parts += "(已撤销)"
            return if (parts.isEmpty()) "资产和订阅没有改动。" else parts.joinToString(";")
        }

    fun toJson(): String = JSONObject()
        .put("lines", JSONArray(lines.map {
            JSONObject().put("domain", it.domain).put("created", it.created).put("uuid", it.uuid)
                .put("title", it.title).put("detail", it.detail)
        }))
        .put("assetsBefore", JSONArray(assetsBefore.map { it.toJson() }))
        .put("feedsBefore", JSONArray(feedsBefore.map { it.toJson() }))
        .put("skipped", JSONArray(skipped)).put("reverted", reverted).toString()

    companion object {
        fun decode(json: String?): LibraryEditRecord? = json?.let {
            runCatching {
                val o = JSONObject(it)
                val lines = o.optJSONArray("lines")?.let { a ->
                    (0 until a.length()).map { i ->
                        val l = a.getJSONObject(i)
                        Line(l.getString("domain"), l.optBoolean("created"), l.getString("uuid"), l.optString("title"), l.optString("detail"))
                    }
                } ?: emptyList()
                LibraryEditRecord(
                    lines,
                    o.optJSONArray("assetsBefore")?.let { a -> (0 until a.length()).map { i -> memoryFromJson(a.getJSONObject(i)) } } ?: emptyList(),
                    o.optJSONArray("feedsBefore")?.let { a -> (0 until a.length()).map { i -> newsFeedFromJson(a.getJSONObject(i)) } } ?: emptyList(),
                    o.optJSONArray("skipped")?.let { a -> (0 until a.length()).map { i -> a.getString(i) } } ?: emptyList(),
                    o.optBoolean("reverted"),
                )
            }.getOrNull()
        }
    }
}

fun formatAmount(value: Double, currency: String): String {
    val v = if (value % 1.0 == 0.0) String.format(Locale.ROOT, "%,.0f", value) else String.format(Locale.ROOT, "%,.2f", value)
    return "$currency $v"
}

/** AI 对资产台账与新闻订阅的写操作:直接执行、结果带撤销(同 iOS LibraryStore)。 */
class LibraryRepository(private val db: LodoDatabase, private val memories: MemoryRepository, private val news: NewsRepository) {
    private val mem get() = db.memoryDao()

    suspend fun apply(assetOps: List<AssetOp>, feedOps: List<FeedOp>): LibraryEditRecord {
        val lines = mutableListOf<LibraryEditRecord.Line>()
        val assetsBefore = mutableListOf<MemoryEntity>()
        val feedsBefore = mutableListOf<NewsFeedEntity>()
        val skipped = mutableListOf<String>()
        for (op in assetOps) {
            when (op) {
                is AssetOp.Create -> {
                    val d = op.draft
                    val category = d.category.ifBlank { "其他" }
                    val item = memories.saveAsset(d.title, d.value, d.currency, d.liability, d.interestRate,
                        listOf(category), note = d.note)
                    lines += LibraryEditRecord.Line("asset", true, item.uuid, d.title, assetDetail(d.value, d.liability, d.currency))
                }
                is AssetOp.Update -> {
                    val old = mem.byUuid(op.id)
                    if (old == null) { skipped += L("找不到要修改的资产", "Asset not found"); continue }
                    val c = op.change
                    val tags = if (c.category != null) {
                        (listOf(MemoryEntity.assetTagName, c.category) + old.tagsList.filter { it in MemoryEntity.reservedTagNames && it != MemoryEntity.assetTagName }).distinct()
                    } else old.tagsList
                    val updated = old.copy(
                        title = c.title ?: old.title, assetValue = c.value ?: old.assetValue,
                        assetCurrency = c.currency ?: old.assetCurrency, assetLiability = c.liability ?: old.assetLiability,
                        assetInterestRate = c.interestRate ?: old.assetInterestRate, summary = c.note ?: old.summary,
                        tags = joinCsv(tags), assetUpdatedAtMillis = System.currentTimeMillis(),
                    )
                    mem.upsert(updated)
                    assetsBefore += old
                    lines += LibraryEditRecord.Line("asset", false, old.uuid, updated.title,
                        assetDetail(updated.assetValue, updated.assetLiability, updated.assetCurrencyOrDefault))
                }
            }
        }
        for (op in feedOps) {
            when (op) {
                is FeedOp.Subscribe -> when (val r = news.subscribe(op.draft.url, op.draft.name, op.draft.kind)) {
                    is NewsRepository.SubscribeResult.Added ->
                        lines += LibraryEditRecord.Line("feed", true, r.feed.uuid, r.feed.title, " " + r.feed.url)
                    is NewsRepository.SubscribeResult.AlreadySubscribed ->
                        skipped += L("「${r.feed.title}」已经订过了", "Already subscribed to \"${r.feed.title}\"")
                    is NewsRepository.SubscribeResult.Failed -> skipped += r.reason
                }
                is FeedOp.Update -> {
                    val old = db.newsDao().feed(op.id)
                    if (old == null) { skipped += L("找不到要修改的订阅", "Feed not found"); continue }
                    val c = op.change
                    val updated = old.copy(title = c.title ?: old.title, kind = c.kind ?: old.kind, enabled = c.enabled ?: old.enabled)
                    db.newsDao().upsertFeed(updated)
                    feedsBefore += old
                    lines += LibraryEditRecord.Line("feed", false, old.uuid, updated.title,
                        if (!updated.enabled) L("(已停用)", " (paused)") else "")
                }
            }
        }
        return LibraryEditRecord(lines, assetsBefore, feedsBefore, skipped)
    }

    suspend fun revert(record: LibraryEditRecord) {
        record.lines.filter { it.created }.forEach { line ->
            if (line.domain == "asset") memories.delete(line.uuid) else news.deleteFeed(line.uuid)
        }
        record.assetsBefore.forEach { mem.upsert(it) }
        record.feedsBefore.forEach { db.newsDao().upsertFeed(it) }
    }

    private fun assetDetail(value: Double?, liability: Double?, currency: String): String = listOfNotNull(
        value?.let { " " + formatAmount(it, currency) },
        liability?.let { L(" 负债 ", " liability ") + formatAmount(it, currency) },
    ).joinToString("")

    /** prompt 里的资产清单。 */
    suspend fun assetEntries() = mem.all().filter { it.isAsset }.map {
        com.lodo.app.ai.AssetPromptEntry(
            it.uuid, it.title, AssetCategory.category(it.tagsList, MemoryEntity.reservedTagNames), it.assetValue,
            it.assetCurrencyOrDefault, it.assetLiability, it.assetInterestRate, it.assetUpdatedAt.toLocalDateTime(),
        )
    }
}
