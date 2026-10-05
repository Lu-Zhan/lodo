package com.lodo.app.core

/** 阅读模式的正文块,对应 iOS ArticleContent。 */
sealed interface ArticleBlock {
    data class Heading(val text: String) : ArticleBlock
    data class Paragraph(val text: String) : ArticleBlock
    data class Quote(val text: String) : ArticleBlock
    data class ListItem(val text: String) : ArticleBlock
    data class Image(val url: String) : ArticleBlock
}

/**
 * 从网页 HTML 里挑正文并按块级元素顺序抽出来(小标题/段落/引用/列表项/图片),
 * 同 iOS ArticleContent 的思路:JSON-LD articleBody → 最长 `<article>` → 全页去掉
 * nav/header/footer/aside 后的块;小图标、1 像素图去掉,同图只留一次;
 * 遇到「相关阅读」这类尾巴小标题截断。纯正则,不引 HTML 解析库。
 */
object ArticleContent {
    private val tailHeadings = listOf("相关阅读", "相关文章", "推荐阅读", "延伸阅读", "more recent articles", "related", "you may also like", "猜你喜欢")

    fun extract(html: String, baseUrl: String, title: String = ""): List<ArticleBlock> {
        val scope = pickScope(html)
        val blocks = mutableListOf<ArticleBlock>()
        val seenImages = mutableSetOf<String>()
        val pattern = Regex("(?is)<(h[2-6]|p|blockquote|li|img)(\\s[^>]*)?>(.*?)</\\1>|<img\\s[^>]*>")
        for (m in pattern.findAll(scope)) {
            val whole = m.value
            if (whole.startsWith("<img", ignoreCase = true)) {
                imageUrl(whole, baseUrl)?.let { if (seenImages.add(it)) blocks += ArticleBlock.Image(it) }
                continue
            }
            val tag = m.groupValues[1].lowercase()
            val inner = m.groupValues[3]
            // 段落里夹着的图片单独成块。
            Regex("(?is)<img\\s[^>]*>").findAll(inner).forEach { img ->
                imageUrl(img.value, baseUrl)?.let { if (seenImages.add(it)) blocks += ArticleBlock.Image(it) }
            }
            val text = FeedParser.htmlToText(inner).replace("\n", " ").trim()
            if (text.isEmpty()) continue
            when {
                tag.startsWith("h") -> {
                    if (text == title.trim()) continue
                    if (tailHeadings.any { text.lowercase().contains(it) }) break
                    blocks += ArticleBlock.Heading(text)
                }
                tag == "blockquote" -> blocks += ArticleBlock.Quote(text)
                tag == "li" -> blocks += ArticleBlock.ListItem(text)
                else -> blocks += ArticleBlock.Paragraph(text)
            }
        }
        return dropNavigationLists(blocks)
    }

    /** 连续 3 个以上很短的列表项当导航/归档去掉。 */
    private fun dropNavigationLists(blocks: List<ArticleBlock>): List<ArticleBlock> {
        val out = mutableListOf<ArticleBlock>()
        var i = 0
        while (i < blocks.size) {
            if (blocks[i] is ArticleBlock.ListItem) {
                var j = i
                while (j < blocks.size && blocks[j] is ArticleBlock.ListItem) j++
                val run = blocks.subList(i, j)
                val short = run.all { (it as ArticleBlock.ListItem).text.length < 16 }
                if (!(run.size >= 3 && short)) out += run
                i = j
            } else {
                out += blocks[i]
                i++
            }
        }
        return out
    }

    private fun pickScope(html: String): String {
        val articles = Regex("(?is)<article[^>]*>(.*?)</article>").findAll(html).map { it.groupValues[1] }.toList()
        val best = articles.maxByOrNull { it.length }
        if (best != null && FeedParser.htmlToText(best).length > 300) return best
        var s = html
        listOf("nav", "header", "footer", "aside", "script", "style", "form").forEach { t ->
            s = s.replace(Regex("(?is)<$t[^>]*>.*?</$t>"), " ")
        }
        return s
    }

    private fun imageUrl(tag: String, base: String): String? {
        val attrs = listOf("data-src", "data-original", "data-lazy-src", "data-actualsrc", "src")
        var url: String? = null
        for (a in attrs) {
            url = Regex("(?i)\\s$a=[\"']([^\"']+)").find(tag)?.groupValues?.get(1)
            if (!url.isNullOrBlank() && !url.startsWith("data:")) break
            url = null
        }
        url ?: return null
        val w = Regex("(?i)\\swidth=[\"']?(\\d+)").find(tag)?.groupValues?.get(1)?.toIntOrNull()
        val h = Regex("(?i)\\sheight=[\"']?(\\d+)").find(tag)?.groupValues?.get(1)?.toIntOrNull()
        if ((w != null && w < 48) || (h != null && h < 48)) return null
        var resolved = FeedParser.resolve(base, FeedParser.decodeEntities(url))
        if (resolved.startsWith("//")) resolved = "https:$resolved"
        if (resolved.startsWith("http://")) resolved = "https://" + resolved.removePrefix("http://")
        val lower = resolved.lowercase()
        if (listOf("icon", "logo", "avatar", "emoji", "pixel", "spacer").any { lower.contains(it) } && !lower.contains("upload")) return null
        return resolved
    }

    /** 抽不出结构时退回纯文本分段。 */
    fun fromPlainText(text: String): List<ArticleBlock> =
        text.split(Regex("\\n\\s*\\n|\\n")).map { it.trim() }.filter { it.isNotEmpty() }.map { ArticleBlock.Paragraph(it) }

    fun plainText(blocks: List<ArticleBlock>): String = blocks.mapNotNull {
        when (it) {
            is ArticleBlock.Heading -> it.text
            is ArticleBlock.Paragraph -> it.text
            is ArticleBlock.Quote -> it.text
            is ArticleBlock.ListItem -> "• " + it.text
            is ArticleBlock.Image -> null
        }
    }.joinToString("\n")
}

/** 新闻纯逻辑:关键词检索、给 AI 的清单,同 iOS NewsPlan。 */
object NewsPlan {
    data class Line(val id: String, val source: String, val title: String, val published: java.time.LocalDateTime, val summary: String, val link: String)

    /** 关键词检索:整句匹配不上时退回两字切片(中文没有空格分词)。 */
    fun search(query: String, lines: List<Line>, limit: Int = 8): List<Line> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return lines.sortedByDescending { it.published }.take(limit)
        fun hay(l: Line) = "${l.title} ${l.summary} ${l.source}".lowercase()
        val direct = lines.filter { hay(it).contains(q) }
        if (direct.isNotEmpty()) return direct.sortedByDescending { it.published }.take(limit)
        val terms = q.split(Regex("\\s+")).filter { it.isNotEmpty() }.flatMap { t ->
            if (t.length <= 2 || t.all { it.code < 128 }) listOf(t) else (0 until t.length - 1).map { t.substring(it, it + 2) }
        }.distinct()
        if (terms.isEmpty()) return emptyList()
        return lines.map { l -> l to terms.count { hay(l).contains(it) } }
            .filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<Line, Int>> { it.second }.thenByDescending { it.first.published })
            .take(limit).map { it.first }
    }

    private val fmt = java.time.format.DateTimeFormatter.ofPattern("MM-dd HH:mm")

    fun promptLines(lines: List<Line>, numbered: Boolean = false, includeLink: Boolean = false): String =
        lines.mapIndexed { i, l ->
            val head = if (numbered) "${i + 1}. " else "- "
            head + "【${l.source}】${l.title}(${l.published.format(fmt)})" +
                (if (l.summary.isNotBlank()) ":" + l.summary.take(120).replace("\n", " ") else "") +
                (if (includeLink && l.link.isNotBlank()) " ${l.link}" else "")
        }.joinToString("\n")
}

/** 菜单纯逻辑:分类按首次出现顺序、没分类的收在最后;一道标价的都没有时合计为 null(同 iOS MenuPlan)。 */
object MenuPlan {
    fun <T> grouped(dishes: List<T>, category: (T) -> String): List<Pair<String, List<T>>> {
        val named = dishes.filter { category(it).isNotBlank() }
        val groups = PackingPlan.grouped(named, category)
        val rest = dishes.filter { category(it).isBlank() }
        return if (rest.isEmpty()) groups else groups + ("" to rest)
    }

    data class Total(val amount: Double?, val unpricedCount: Int)

    fun total(prices: List<Double?>): Total {
        val priced = prices.filterNotNull()
        return Total(if (priced.isEmpty()) null else priced.sum(), prices.count { it == null })
    }
}
