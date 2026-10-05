package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime

/** 倒数日/资产收支/旅行/新闻/菜单纯逻辑离线单测,基准时间同调度器测试(2026-07-08 周三 09:00)。 */
class LibraryPlansTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)

    @Test
    fun countdownAllDayEndDayCountsAsOngoing() {
        val e = CountdownEntry("a", "假期", LocalDateTime.of(2026, 7, 6, 0, 0), LocalDateTime.of(2026, 7, 8, 0, 0))
        val span = CountdownPlan.primary(e, now)
        assertEquals(CountdownSpan.Milestone.UNTIL_END, span.milestone)
        assertEquals(0, span.days)
        assertFalse(CountdownPlan.isPast(e, now))
    }

    @Test
    fun singleDayTodayIsNotPast() {
        val e = CountdownEntry("a", "考试", LocalDateTime.of(2026, 7, 8, 0, 0))
        assertFalse(CountdownPlan.isPast(e, now))
        assertTrue(CountdownPlan.isPast(e, now.plusDays(1)))
    }

    @Test
    fun anniversaryMilestone() {
        val e = CountdownEntry("a", "在一起", LocalDateTime.of(2024, 7, 11, 0, 0))
        val m = CountdownPlan.milestones(e, now).first()
        assertEquals(CountdownPlan.MilestoneKind.Anniversary(2), m.kind)
        assertEquals(3, m.daysAway)
        assertTrue(CountdownPlan.promptSummary(listOf(e), now).contains("3 天后满 2 周年"))
    }

    @Test
    fun remindersUseAllDayTimeAndSkipArchived() {
        val e = CountdownEntry("a", "搬家", LocalDateTime.of(2026, 7, 10, 0, 0), startReminders = listOf(1440, 0))
        val r = CountdownPlan.reminders(listOf(e, e.copy(id = "b", archived = true)), "09:00", now)
        assertEquals(listOf(LocalDateTime.of(2026, 7, 9, 9, 0), LocalDateTime.of(2026, 7, 10, 9, 0)), r.map { it.fireAt })
    }

    @Test
    fun monthlyTotalSkipsIrregularAndReportsMissingRates() {
        val list = listOf(
            FinanceSnapshot("1", FinanceKind.INCOME, "工资", 12000.0),
            FinanceSnapshot("2", FinanceKind.EXPENSE, "保险", 1200.0, cadence = FinanceCadence.YEARLY),
            FinanceSnapshot("3", FinanceKind.INCOME, "奖金", 50000.0, cadence = FinanceCadence.IRREGULAR),
            FinanceSnapshot("4", FinanceKind.EXPENSE, "订阅", 10.0, currency = "USD"),
        )
        val t = FinancePlan.monthlyTotal(list, "CNY", now) { _, _, _ -> null }
        assertEquals(12000.0, t.income, 0.001)
        assertEquals(100.0, t.expense, 0.001)
        assertEquals(1, t.irregularCount)
        assertEquals(listOf("USD"), t.missingCurrencies)
    }

    @Test
    fun cardReminderDayBeforeAndMonthEnd() {
        assertEquals(LocalDate.of(2026, 9, 30), FinancePlan.nextDate(31, LocalDate.of(2026, 9, 5)))
        val card = FinanceSnapshot("c", FinanceKind.CREDIT_CARD, "卡", dayOfMonth = 20)
        val r = FinancePlan.reminder(card, "09:00", now)!!
        assertEquals(LocalDateTime.of(2026, 7, 19, 9, 0), r.remindAt)
        assertEquals("2026-07-20", r.cycle)
    }

    @Test
    fun lodgingCoversNightsNotCheckoutDay() {
        val stay = TravelEntry("s", TravelItemKind.LODGING, "酒店", start = LocalDateTime.of(2026, 7, 10, 15, 0), end = LocalDateTime.of(2026, 7, 12, 11, 0))
        val days = TravelPlan.days(LocalDate.of(2026, 7, 10), LocalDate.of(2026, 7, 12))
        assertEquals(listOf(true, true, false), days.map { TravelPlan.covers(stay, it) })
        assertEquals(2, TravelPlan.nights(stay))
    }

    @Test
    fun travelTotalLeavesUnknownCurrency() {
        val list = listOf(
            TravelEntry("a", TravelItemKind.PLACE, "门票", price = 100.0),
            TravelEntry("b", TravelItemKind.PLACE, "寺", price = 500.0, currency = "JPY"),
        )
        val t = TravelPlan.total(list, "CNY") { _, _, _ -> null }
        assertEquals(100.0, t.amount, 0.0)
        assertEquals(listOf("JPY"), t.missingCurrencies)
    }

    @Test
    fun promptSummaryIncludesIds() {
        val list = listOf(TravelEntry("id1", TravelItemKind.PLACE, "浅草寺", start = LocalDateTime.of(2026, 7, 10, 10, 0)))
        val s = TravelPlan.promptSummary("东京", TravelPlan.days(LocalDate.of(2026, 7, 10), LocalDate.of(2026, 7, 11)), list, includeIDs = true)
        assertTrue(s.contains("[id:id1]"))
    }

    @Test
    fun packingSuggestionsDropExisting() {
        assertEquals(listOf("护照"), PackingPlan.newSuggestions(listOf("护照", "充电宝"), listOf("充电宝 20000mAh")))
    }

    @Test
    fun rssParses() {
        val xml = """<?xml version="1.0"?><rss><channel><title>Blog</title><link>https://b.com</link>
            <item><title>Hello &amp; world</title><link>https://b.com/1</link><guid>g1</guid>
            <pubDate>Tue, 07 Jul 2026 10:00:00 +0000</pubDate><description><![CDATA[<p>Hi&nbsp;there</p>]]></description></item></channel></rss>"""
        val feed = FeedParser.parse(xml)!!
        assertEquals("Blog", feed.title)
        assertEquals("Hello & world", feed.items[0].title)
        assertEquals("Hi there", feed.items[0].summary)
        assertEquals("g1", feed.items[0].dedupeKey())
        assertEquals(2026, feed.items[0].published!!.year)
    }

    @Test
    fun atomParses() {
        val xml = """<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><link href="https://a.com/"/>
            <entry><title>Post</title><link rel="alternate" href="https://a.com/p"/><id>x</id><updated>2026-07-01T08:00:00Z</updated><summary>S</summary></entry></feed>"""
        val feed = FeedParser.parse(xml)!!
        assertEquals("https://a.com/", feed.siteUrl)
        assertEquals("https://a.com/p", feed.items[0].link)
    }

    @Test
    fun discoverAlternateLinks() {
        val html = """<head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>"""
        assertEquals(listOf("https://x.com/feed.xml"), FeedParser.discover(html, "https://x.com/blog"))
    }

    @Test
    fun articleContentCutsTail() {
        val html = """<article><h1>T</h1><p>${"正文".repeat(100)}</p><h2>小节</h2><p>更多</p><h2>相关阅读</h2><p>别的</p></article>"""
        val blocks = ArticleContent.extract(html, "https://x.com", "T")
        assertTrue(blocks.none { it is ArticleBlock.Paragraph && it.text == "别的" })
        assertTrue(blocks.any { it is ArticleBlock.Heading && it.text == "小节" })
    }

    @Test
    fun newsSearchFallsBackToBigrams() {
        val l = NewsPlan.Line("1", "源", "苹果发布新键盘", now, "", "")
        assertEquals(1, NewsPlan.search("讲键盘的文章", listOf(l)).size)
    }

    @Test
    fun menuTotalNullWhenNoPrices() {
        assertNull(MenuPlan.total(listOf(null, null)).amount)
        assertEquals(30.0, MenuPlan.total(listOf(10.0, null, 20.0)).amount!!, 0.0)
        val groups = MenuPlan.grouped(listOf("主菜" to 1, "" to 2, "甜点" to 3, "主菜" to 4)) { it.first }
        assertEquals(listOf("主菜", "甜点", ""), groups.map { it.first })
    }

    @Test
    fun healthTrendAndSummary() {
        val pts = (0 until 14).map { HealthDailyPoint(LocalDate.of(2026, 7, 1).plusDays(it.toLong()), if (it < 7) 5000.0 else 6000.0) }
        val r = HealthReport(listOf(HealthSeries(HealthMetricKind.STEPS, pts)), 14)
        assertEquals(0.2, r.trend(HealthMetricKind.STEPS)!!, 0.0001)
        assertTrue(r.promptSummary().contains("上升 20%"))
    }
}
