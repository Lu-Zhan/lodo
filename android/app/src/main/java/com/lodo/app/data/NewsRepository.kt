package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.AIConfig
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.FeedMatch
import com.lodo.app.core.ArticleBlock
import com.lodo.app.core.ArticleContent
import com.lodo.app.core.FeedParser
import com.lodo.app.core.NewsPlan
import com.lodo.app.core.dedupeKey
import com.lodo.app.data.toEpochMillis
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.Charset
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * 新闻订阅:抓 RSS/Atom、按去重键只插新文章(已有的不动,保留已读/收藏/AI 总结)、
 * 清理旧文章、打开时抓全文 + AI 总结、「今日」总结按天缓存。对应 iOS NewsStore。
 */
class NewsRepository(private val context: Context, private val db: LodoDatabase) {
    private val dao get() = db.newsDao()
    private val scheduledMutex = Mutex()

    data class Preset(val title: String, val url: String, val kind: String)

    companion object {
        /** 只放实测对非浏览器请求直接返回 feed 的源(同 iOS presets)。 */
        val presets = listOf(
            Preset("少数派", "https://sspai.com/feed", "news"),
            Preset("IT之家", "https://www.ithome.com/rss/", "news"),
            Preset("BBC 中文", "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", "news"),
            Preset("Hacker News", "https://hnrss.org/frontpage", "news"),
            Preset("小众软件", "https://www.appinn.com/feed/", "blog"),
            Preset("Simon Willison", "https://simonwillison.net/atom/everything/", "blog"),
            Preset("Daring Fireball", "https://daringfireball.net/feeds/main", "blog"),
        )
        private const val BROWSER_UA =
            "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Mobile Safari/537.36"
        private const val KEEP_DAYS = 30L
        private const val PER_FEED_LIMIT = 200
    }

    private val client = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS).followRedirects(true).build()

    /** 全文只在内存里缓存,不落库(同 iOS)。 */
    private val contentCache = ConcurrentHashMap<String, List<ArticleBlock>>()

    fun observeFeeds() = dao.observeFeeds()
    fun observeArticles() = dao.observeArticles()
    fun observeArticle(uuid: String) = dao.observeArticle(uuid)
    suspend fun feeds() = dao.feeds()
    suspend fun articles() = dao.articles()

    private fun get(url: String): Pair<String, String>? = runCatching {
        client.newCall(Request.Builder().url(url).header("User-Agent", BROWSER_UA).build()).execute().use { resp ->
            if (!resp.isSuccessful) return null
            val body = resp.body ?: return null
            val bytes = body.bytes()
            val declared = body.contentType()?.charset()
            var text = String(bytes, declared ?: Charsets.UTF_8)
            // HTML/XML 里声明了 GBK/GB2312 但响应头没写:按声明重新解码。
            val meta = Regex("(?i)(charset|encoding)=[\"']?([\\w-]+)").find(text.take(2000))?.groupValues?.get(2)
            if (declared == null && meta != null && !meta.equals("utf-8", true)) {
                runCatching { text = String(bytes, Charset.forName(if (meta.lowercase().startsWith("gb")) "GB18030" else meta)) }
            }
            resp.request.url.toString() to text
        }
    }.getOrNull()

    /** 解析出订阅地址:本身是 feed 就直接用;是网页就找 <link rel=alternate>,再试惯用路径。 */
    suspend fun resolveFeed(input: String): Pair<String, com.lodo.app.core.ParsedFeed>? = withContext(Dispatchers.IO) {
        var url = input.trim()
        if (!url.startsWith("http")) url = "https://$url"
        val (finalUrl, text) = get(url) ?: return@withContext null
        FeedParser.parse(text)?.takeIf { it.items.isNotEmpty() || it.title.isNotEmpty() }?.let { return@withContext finalUrl to it }
        val candidates = FeedParser.discover(text, finalUrl) +
            FeedParser.commonFeedPaths.map { FeedParser.resolve(finalUrl, it) }
        for (c in candidates.distinct().take(8)) {
            val (u, t) = get(c) ?: continue
            FeedParser.parse(t)?.takeIf { it.items.isNotEmpty() }?.let { return@withContext u to it }
        }
        null
    }

    sealed interface SubscribeResult {
        data class Added(val feed: NewsFeedEntity) : SubscribeResult
        data class AlreadySubscribed(val feed: NewsFeedEntity) : SubscribeResult
        data class Failed(val reason: String) : SubscribeResult
    }

    /** 订阅:有链接按链接;只有名字时按名字在已有订阅和推荐源里模糊找(同 iOS FeedMatch)。 */
    suspend fun subscribe(url: String?, name: String?, kind: String): SubscribeResult {
        val existing = dao.feeds()
        var target = url?.trim()?.takeIf { it.isNotEmpty() }
        if (target == null && name != null) {
            FeedMatch.best(name, existing, { it.title }, { it.url })?.let { return SubscribeResult.AlreadySubscribed(it) }
            target = FeedMatch.best(name, presets, { it.title }, { it.url })?.url
                ?: return SubscribeResult.Failed(com.lodo.app.ui.L("没找到「$name」的订阅地址,发个链接给我", "Couldn't find a feed for \"$name\" — send me a link"))
        }
        target ?: return SubscribeResult.Failed(com.lodo.app.ui.L("缺少链接", "Missing link"))
        existing.firstOrNull { it.url.equals(target, true) || it.siteUrl.equals(target, true) }
            ?.let { return SubscribeResult.AlreadySubscribed(it) }
        val (feedUrl, parsed) = resolveFeed(target)
            ?: return SubscribeResult.Failed(com.lodo.app.ui.L("「$target」里找不到 RSS/Atom 订阅", "No RSS/Atom feed found at $target"))
        existing.firstOrNull { it.url.equals(feedUrl, true) }?.let { return SubscribeResult.AlreadySubscribed(it) }
        val feed = NewsFeedEntity(
            title = name?.takeIf { it.isNotBlank() } ?: parsed.title.ifBlank { runCatching { java.net.URI(feedUrl).host }.getOrDefault(feedUrl) },
            url = feedUrl, siteUrl = parsed.siteUrl, kind = kind, lastFetchedMillis = System.currentTimeMillis(),
        )
        dao.upsertFeed(feed)
        insertItems(feed, parsed)
        return SubscribeResult.Added(feed)
    }

    suspend fun updateFeed(feed: NewsFeedEntity) = dao.upsertFeed(feed)

    /** 删订阅连文章删,收藏的留下(同 iOS)。 */
    suspend fun deleteFeed(uuid: String) {
        dao.deleteUnstarredForFeed(uuid)
        dao.deleteFeed(uuid)
    }

    private suspend fun insertItems(feed: NewsFeedEntity, parsed: com.lodo.app.core.ParsedFeed) {
        val now = System.currentTimeMillis()
        for (item in parsed.items.take(100)) {
            // 发布时间在未来的按抓取时间算。
            val published = item.published?.toEpochMillis()?.coerceAtMost(now) ?: now
            dao.insertArticleIfNew(
                NewsArticleEntity(
                    feedUuid = feed.uuid, dedupeKey = item.dedupeKey(), title = item.title,
                    summary = item.summary, link = item.link, author = item.author, publishedMillis = published,
                )
            )
        }
    }

    /** 刷新订阅:force = false 时半小时内抓过的源跳过(下拉刷新传 true)。 */
    suspend fun refresh(force: Boolean = false) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        for (feed in dao.feeds().filter { it.enabled }) {
            if (!force && feed.lastFetchedMillis != null && now - feed.lastFetchedMillis < 30 * 60_000L) continue
            val (_, text) = get(feed.url) ?: continue
            val parsed = FeedParser.parse(text) ?: continue
            insertItems(feed, parsed)
            dao.upsertFeed(feed.copy(lastFetchedMillis = now))
        }
        cleanup()
    }

    private suspend fun cleanup() {
        val cutoff = System.currentTimeMillis() - KEEP_DAYS * 24 * 3600_000L
        val all = dao.articles()
        all.filter { !it.starred && it.publishedMillis < cutoff }.forEach { dao.deleteArticle(it.uuid) }
        all.groupBy { it.feedUuid }.forEach { (_, list) ->
            list.filter { !it.starred }.sortedByDescending { it.publishedMillis }.drop(PER_FEED_LIMIT)
                .forEach { dao.deleteArticle(it.uuid) }
        }
    }

    suspend fun setRead(uuid: String, read: Boolean) { dao.article(uuid)?.let { dao.upsertArticle(it.copy(read = read)) } }
    suspend fun toggleStar(uuid: String) { dao.article(uuid)?.let { dao.upsertArticle(it.copy(starred = !it.starred)) } }

    /** 打开文章:抓全文并按块抽正文;抽不出来退回 feed 摘要(如实说明由调用方负责)。 */
    suspend fun content(article: NewsArticleEntity): List<ArticleBlock> = withContext(Dispatchers.IO) {
        contentCache[article.uuid]?.let { return@withContext it }
        fun good(b: List<ArticleBlock>?) = b?.takeIf { ArticleContent.plainText(it).length > 200 }
        val link = article.link.takeIf { it.startsWith("http") }
        // 逐级退路(同 iOS NewsStore.fullText):直接抓 → 本机渲染一遍再抽 → r.jina.ai → feed 摘要。
        val blocks = good(link?.let { l -> get(l)?.let { (final, html) -> ArticleContent.extract(html, final, article.title) } })
            ?: good(link?.let { l -> RenderedPageLoader.html(context, l)?.let { ArticleContent.extract(it, l, article.title) } })
            ?: readerFallback(article.link)
            ?: ArticleContent.fromPlainText(article.summary)
        contentCache[article.uuid] = blocks
        blocks
    }

    /** 公开阅读服务 r.jina.ai(只发文章链接),Markdown 按行解析成块;失败返回 null。 */
    private fun readerFallback(link: String): List<ArticleBlock>? {
        if (!link.startsWith("http")) return null
        val (_, md) = get("https://r.jina.ai/$link") ?: return null
        val blocks = md.lines().mapNotNull { raw ->
            val line = raw.trim()
            when {
                line.isEmpty() || line.startsWith("Title:") || line.startsWith("URL Source:") || line.startsWith("Markdown Content:") -> null
                line.startsWith("![") -> Regex("\\((https?://[^)\\s]+)").find(line)?.groupValues?.get(1)?.let { ArticleBlock.Image(it) }
                line.startsWith("#") -> ArticleBlock.Heading(line.trimStart('#', ' '))
                line.startsWith(">") -> ArticleBlock.Quote(line.trimStart('>', ' '))
                line.startsWith("- ") || line.startsWith("* ") -> ArticleBlock.ListItem(line.drop(2))
                else -> ArticleBlock.Paragraph(line.replace(Regex("\\[([^]]+)]\\([^)]+\\)"), "$1"))
            }
        }
        return blocks.takeIf { ArticleContent.plainText(it).length > 200 }
    }

    /** 阅读设置里选的总结语言,单篇总结和「今日」共用(同 iOS NewsStore.summaryLanguageName)。 */
    private suspend fun summaryLanguage(): String =
        com.lodo.app.core.NewsSummaryLanguage.from(app().settings.snapshot().newsSummaryLanguage).promptName(DeepSeekClient.languageName())

    private fun app() = context.applicationContext as com.lodo.app.LodoApp

    /** 没总结过时 AI 总结并存进 aiSummaryJson;force 重新总结。 */
    suspend fun summarize(config: AIConfig, article: NewsArticleEntity, force: Boolean = false): DeepSeekClient.ArticleSummary {
        if (!force) DeepSeekClient.ArticleSummary.decode(article.aiSummaryJson)?.let { return it }
        val feed = dao.feed(article.feedUuid)
        val text = ArticleContent.plainText(content(article)).ifBlank { article.summary }
        val summary = DeepSeekClient.summarizeArticle(config, article.title, feed?.title ?: "", text, summaryLanguage())
        dao.article(article.uuid)?.let { dao.upsertArticle(it.copy(aiSummaryJson = summary.toJson())) }
        return summary
    }

    suspend fun lines(enabledOnly: Boolean, feedUuid: String? = null): List<NewsPlan.Line> {
        val feeds = dao.feeds().associateBy { it.uuid }
        return dao.articles().filter { a ->
            (feedUuid == null || a.feedUuid == feedUuid) &&
                (feeds[a.feedUuid]?.let { !enabledOnly || it.enabled } ?: true)
        }.map {
            NewsPlan.Line(it.uuid, feeds[it.feedUuid]?.title ?: "", it.title, it.publishedMillis.toLocalDateTime(), it.summary, it.link)
        }
    }

    /** 最近 24 小时的文章(未读优先,只取启用中的订阅),给「今日」总结和定时推送用。 */
    suspend fun digestCandidates(limit: Int = 40, feedUuid: String? = null): List<NewsPlan.Line> {
        val since = LocalDateTime.now().minusHours(24)
        val unread = dao.articles().filter { !it.read }.map { it.uuid }.toSet()
        return lines(enabledOnly = true, feedUuid = feedUuid).filter { it.published.isAfter(since) }
            .sortedWith(compareByDescending<NewsPlan.Line> { it.id in unread }.thenByDescending { it.published })
            .take(limit)
    }

    /** 「今日」总结:按天缓存在 SharedPreferences(纯展示派生数据,不进库不备份)。 */
    data class DigestCache(val day: String, val generatedAt: Long, val digest: DeepSeekClient.NewsDigest, val refs: List<List<String>>)

    fun cachedDigest(feedUuid: String? = null): DigestCache? {
        val key = feedUuid?.let { "digest.$it" } ?: "digest"
        val json = context.getSharedPreferences("news", 0).getString(key, null) ?: return null
        return runCatching {
            val o = JSONObject(json)
            if (o.getString("day") != LocalDate.now().toString()) return null
            val items = o.getJSONArray("items")
            val list = (0 until items.length()).map { i ->
                val it = items.getJSONObject(i)
                DeepSeekClient.NewsDigestItem(it.getString("title"), it.optString("detail"), emptyList()) to
                    (it.optJSONArray("articles")?.let { a -> (0 until a.length()).map { j -> a.getString(j) } } ?: emptyList())
            }
            DigestCache(o.getString("day"), o.getLong("at"), DeepSeekClient.NewsDigest(o.optString("overview"), list.map { it.first }), list.map { it.second })
        }.getOrNull()
    }

    suspend fun generateDigest(config: AIConfig, feedUuid: String? = null): DigestCache {
        refresh()
        val candidates = digestCandidates(feedUuid = feedUuid)
        if (candidates.isEmpty()) throw IllegalStateException(com.lodo.app.ui.L("最近 24 小时订阅里没有新文章", "No new articles in the last 24 hours"))
        val digest = DeepSeekClient.newsDigest(config, NewsPlan.promptLines(candidates, numbered = true), summaryLanguage())
        val refs = digest.items.map { item -> item.refs.mapNotNull { candidates.getOrNull(it - 1)?.id }.distinct() }
        val cache = DigestCache(LocalDate.now().toString(), System.currentTimeMillis(), digest, refs)
        val items = JSONArray()
        digest.items.forEachIndexed { i, item ->
            items.put(JSONObject().put("title", item.title).put("detail", item.detail).put("articles", JSONArray(refs[i])))
        }
        context.getSharedPreferences("news", 0).edit().putString(
            (feedUuid?.let { "digest.$it" } ?: "digest"), JSONObject().put("day", cache.day).put("at", cache.generatedAt)
                .put("overview", digest.overview).put("items", items).toString(),
        ).apply()
        return cache
    }

    data class CategoryCache(val generatedAt: Long, val categories: List<Pair<String, DigestCache>>)

    fun cachedCategories(): CategoryCache? {
        val json = context.getSharedPreferences("news", 0).getString("categories", null) ?: return null
        return runCatching {
            val root = JSONObject(json)
            if (root.getString("day") != LocalDate.now().toString()) return null
            val array = root.getJSONArray("categories")
            val categories = (0 until array.length()).map { i ->
                val raw = array.getJSONObject(i)
                val items = raw.getJSONArray("items")
                val parsed = (0 until items.length()).map { j ->
                    val item = items.getJSONObject(j)
                    DeepSeekClient.NewsDigestItem(item.getString("title"), item.optString("detail"), emptyList()) to
                        (item.optJSONArray("articles")?.let { refs -> (0 until refs.length()).map { k -> refs.getString(k) } } ?: emptyList())
                }
                raw.getString("name") to DigestCache(root.getString("day"), root.getLong("at"),
                    DeepSeekClient.NewsDigest(raw.optString("overview"), parsed.map { it.first }), parsed.map { it.second })
            }
            CategoryCache(root.getLong("at"), categories)
        }.getOrNull()
    }

    suspend fun generateCategories(config: AIConfig): CategoryCache {
        refresh()
        val candidates = digestCandidates()
        if (candidates.isEmpty()) throw IllegalStateException("最近 24 小时订阅里没有新文章")
        val aliases = context.getSharedPreferences("news", 0).getString("categoryNames", "{}")?.let(::JSONObject) ?: JSONObject()
        val generated = DeepSeekClient.newsCategoryDigests(config, NewsPlan.promptLines(candidates, numbered = true), summaryLanguage())
        if (generated.isEmpty()) throw IllegalStateException("暂时无法按内容分类,可以重新生成。")
        val at = System.currentTimeMillis()
        val jsonCategories = JSONArray()
        val categories = generated.map { category ->
            val name = aliases.optString(category.name, category.name)
            val refs = category.digest.items.map { item -> item.refs.mapNotNull { candidates.getOrNull(it - 1)?.id }.distinct() }
            val items = JSONArray()
            category.digest.items.forEachIndexed { i, item ->
                items.put(JSONObject().put("title", item.title).put("detail", item.detail).put("articles", JSONArray(refs[i])))
            }
            jsonCategories.put(JSONObject().put("name", name).put("overview", category.digest.overview).put("items", items))
            name to DigestCache(LocalDate.now().toString(), at, category.digest, refs)
        }
        context.getSharedPreferences("news", 0).edit().putString("categories", JSONObject()
            .put("day", LocalDate.now().toString()).put("at", at).put("categories", jsonCategories).toString()).apply()
        return CategoryCache(at, categories)
    }

    fun renameCategory(old: String, new: String) {
        val name = new.trim()
        if (name.isEmpty()) return
        val preferences = context.getSharedPreferences("news", 0)
        val aliases = JSONObject(preferences.getString("categoryNames", "{}") ?: "{}")
        val keys = aliases.keys().asSequence().filter { aliases.optString(it) == old }.toList()
        if (keys.isEmpty()) aliases.put(old, name) else keys.forEach { aliases.put(it, name) }
        preferences.edit().putString("categoryNames", aliases.toString()).apply()
        val cache = preferences.getString("categories", null)?.let(::JSONObject) ?: return
        val categories = cache.optJSONArray("categories") ?: return
        for (i in 0 until categories.length()) {
            val item = categories.getJSONObject(i)
            if (item.optString("name") == old) item.put("name", name)
        }
        preferences.edit().putString("categories", cache.toString()).apply()
    }

    /** 同一个时间槽统一生成一览、各来源和内容分类；失败后保留已完成缓存供下次补做。 */
    fun scheduledDoneToday(): Boolean = context.getSharedPreferences("news", 0)
        .getString("scheduledDay", null) == LocalDate.now().toString()

    suspend fun runScheduledDigests(config: AIConfig, time: String, force: Boolean = false) {
        val due = runCatching { LocalTime.parse(time) }.getOrDefault(LocalTime.of(9, 0))
        val day = LocalDate.now().toString()
        val dueMillis = LocalDate.now().atTime(due).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        val preferences = context.getSharedPreferences("news", 0)
        if (!force && (LocalTime.now().isBefore(due) || preferences.getString("scheduledDay", null) == day)) return
        scheduledMutex.lock()
        try {
            if (!force && preferences.getString("scheduledDay", null) == day) return
            refresh()
            if (digestCandidates().isEmpty()) {
                if (!force || !LocalTime.now().isBefore(due)) {
                    preferences.edit().putString("scheduledDay", day).apply()
                }
                return
            }
            if (force || (cachedDigest()?.generatedAt ?: 0L) < dueMillis) generateDigest(config)
            feeds().filter { it.enabled }.forEach { feed ->
                if (digestCandidates(feedUuid = feed.uuid).isNotEmpty() &&
                    (force || (cachedDigest(feed.uuid)?.generatedAt ?: 0L) < dueMillis)) generateDigest(config, feed.uuid)
            }
            if (force || (cachedCategories()?.generatedAt ?: 0L) < dueMillis) generateCategories(config)
            if (!force || !LocalTime.now().isBefore(due)) {
                preferences.edit().putString("scheduledDay", day).apply()
            }
        } finally {
            scheduledMutex.unlock()
        }
    }
}
