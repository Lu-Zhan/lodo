package com.lodo.app.core

import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.StringReader
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.parsers.SAXParserFactory

/** 解析出来的一篇文章(还没落库)。 */
data class FeedItem(
    val guid: String?,
    val title: String,
    val link: String,
    val summary: String,
    val author: String,
    val published: LocalDateTime?,
)

data class ParsedFeed(val title: String, val siteUrl: String, val items: List<FeedItem>)

/**
 * RSS 2.0 / RDF / Atom 解析,对应 iOS FeedParser。用 JVM 自带的 SAX(Android 也有),
 * 不引第三方库;HTML → 纯文本用正则,摘要截到 600 字。
 */
object FeedParser {
    const val SUMMARY_LIMIT = 600

    fun parse(xml: String): ParsedFeed? {
        val handler = Handler()
        return try {
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = false
            runCatching { factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", false) }
            factory.newSAXParser().parse(InputSource(StringReader(sanitize(xml))), handler)
            handler.result()
        } catch (_: Exception) {
            handler.result().takeIf { it.items.isNotEmpty() }
        }
    }

    /** 有的源在 XML 声明前面带 BOM/空白,或者用了 HTML 实体(&nbsp;)——SAX 会直接报错。 */
    private fun sanitize(xml: String): String {
        var s = xml.trimStart('﻿', ' ', '\n', '\r', '\t')
        s = s.replace("&nbsp;", "&#160;").replace("&mdash;", "&#8212;").replace("&ndash;", "&#8211;")
            .replace("&hellip;", "&#8230;").replace("&rsquo;", "&#8217;").replace("&lsquo;", "&#8216;")
            .replace("&ldquo;", "&#8220;").replace("&rdquo;", "&#8221;")
        return s
    }

    private class Handler : DefaultHandler() {
        var feedTitle = ""
        var siteUrl = ""
        val items = mutableListOf<FeedItem>()
        private var inItem = false
        private val text = StringBuilder()
        private var cur = mutableMapOf<String, String>()
        private var depthInItem = 0

        fun result() = ParsedFeed(feedTitle.trim(), siteUrl.trim(), items)

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            val name = qName.lowercase()
            text.setLength(0)
            if (name == "item" || name == "entry") {
                inItem = true
                cur = mutableMapOf()
                return
            }
            if (name == "link") {
                val href = attributes.getValue("href")
                val rel = attributes.getValue("rel")
                if (href != null) {
                    if (inItem) {
                        if (rel == null || rel == "alternate") cur.putIfAbsent("link", href)
                    } else if ((rel == null || rel == "alternate") && siteUrl.isEmpty()) {
                        siteUrl = href
                    }
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            text.appendRange(ch, start, start + length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            val name = qName.lowercase()
            val value = text.toString().trim()
            if (inItem) {
                when (name) {
                    "item", "entry" -> {
                        inItem = false
                        val title = htmlToText(cur["title"].orEmpty()).take(300)
                        val link = cur["link"].orEmpty().trim()
                        if (title.isNotEmpty() || link.isNotEmpty()) {
                            val body = cur["description"] ?: cur["summary"] ?: cur["content:encoded"] ?: cur["content"] ?: ""
                            items += FeedItem(
                                guid = cur["guid"] ?: cur["id"],
                                title = title.ifEmpty { link },
                                link = link,
                                summary = htmlToText(body).take(SUMMARY_LIMIT),
                                author = htmlToText(cur["author"] ?: cur["dc:creator"] ?: cur["name"] ?: ""),
                                published = parseDate(cur["pubdate"] ?: cur["published"] ?: cur["updated"] ?: cur["dc:date"]),
                            )
                        }
                    }
                    "link" -> if (value.isNotEmpty()) cur.putIfAbsent("link", value)
                    else -> if (value.isNotEmpty()) cur.putIfAbsent(name, value)
                }
            } else {
                when (name) {
                    "title" -> if (feedTitle.isEmpty()) feedTitle = htmlToText(value)
                    "link" -> if (siteUrl.isEmpty() && value.isNotEmpty()) siteUrl = value
                }
            }
            text.setLength(0)
        }
    }

    private val rfc822 = listOf(
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss z", "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss",
    ).map { DateTimeFormatter.ofPattern(it, Locale.ENGLISH) }

    fun parseDate(raw: String?): LocalDateTime? {
        val s = raw?.trim()?.replace(Regex("\\s+"), " ") ?: return null
        if (s.isEmpty()) return null
        val zone = ZoneId.systemDefault()
        runCatching { return OffsetDateTime.parse(s).atZoneSameInstant(zone).toLocalDateTime() }
        runCatching { return ZonedDateTime.parse(s).withZoneSameInstant(zone).toLocalDateTime() }
        runCatching { return LocalDateTime.parse(s) }
        for (f in rfc822) {
            runCatching { return ZonedDateTime.parse(s, f).withZoneSameInstant(zone).toLocalDateTime() }
            runCatching { return LocalDateTime.parse(s, f) }
        }
        // "GMT"/"UT" 这类写法 Z 认不出,换成 +0000 再试一次。
        val fixed = s.replace(Regex(" (GMT|UT|UTC)$"), " +0000")
        if (fixed != s) return parseDate(fixed)
        runCatching { return java.time.LocalDate.parse(s.take(10)).atStartOfDay() }
        return null
    }

    /** HTML → 纯文本:去 script/style/标签、解实体、折叠空白。 */
    fun htmlToText(html: String): String {
        var s = html
        s = s.replace(Regex("(?is)<(script|style)[^>]*>.*?</\\1>"), " ")
        s = s.replace(Regex("(?is)<!--.*?-->"), " ")
        s = s.replace(Regex("(?i)<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>"), "\n")
        s = s.replace(Regex("(?s)<[^>]+>"), " ")
        s = decodeEntities(s)
        s = s.replace(Regex("[ \\t\\u00A0]+"), " ").replace(Regex("\\s*\\n\\s*"), "\n").replace(Regex("\\n{3,}"), "\n\n")
        return s.trim()
    }

    fun decodeEntities(text: String): String {
        var s = text
        s = Regex("&#(x?[0-9a-fA-F]+);").replace(s) { m ->
            val v = m.groupValues[1]
            val code = if (v.startsWith("x") || v.startsWith("X")) v.drop(1).toIntOrNull(16) else v.toIntOrNull()
            code?.let { runCatching { String(Character.toChars(it)) }.getOrNull() } ?: m.value
        }
        return s.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
            .replace("&#39;", "'").replace("&apos;", "'").replace("&amp;", "&")
    }

    /** 从网站首页 HTML 里找 `<link rel="alternate" type="application/rss+xml">`,对应 iOS FeedDiscovery。 */
    fun discover(html: String, base: String): List<String> {
        val result = mutableListOf<String>()
        Regex("(?is)<link[^>]+>").findAll(html).forEach { m ->
            val tag = m.value
            val type = Regex("(?i)type=[\"']([^\"']+)").find(tag)?.groupValues?.get(1)?.lowercase() ?: return@forEach
            if (!type.contains("rss") && !type.contains("atom")) return@forEach
            val href = Regex("(?i)href=[\"']([^\"']+)").find(tag)?.groupValues?.get(1) ?: return@forEach
            result += resolve(base, decodeEntities(href))
        }
        return result.distinct()
    }

    fun resolve(base: String, href: String): String = runCatching {
        java.net.URI(base).resolve(href.trim()).toString()
    }.getOrDefault(href)

    /** 订阅时的惯用路径,同 iOS。 */
    val commonFeedPaths = listOf("/feed", "/rss.xml", "/atom.xml", "/feed.xml", "/rss", "/index.xml")
}

/** 文章去重键:guid → 链接 → 标题,同 iOS。 */
fun FeedItem.dedupeKey(): String = (guid?.takeIf { it.isNotBlank() } ?: link.takeIf { it.isNotBlank() } ?: title).take(500)
