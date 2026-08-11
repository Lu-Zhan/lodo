package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** MemorySearch 纯逻辑单测,1:1 移植自 ios/LodoCore/Tests/LodoCoreTests/MemoryTests.swift
 * 里与 Android 对应的部分(truncate/rank/rankTaskHistory/tokens)。Android 的
 * truncate 是纯截断(不像 iOS 那样裁剪首尾空白、超长时加省略号后缀),这里按
 * Android 实际行为断言,不强行对齐 iOS 的文案细节。 */
class MemorySearchTest {
    private data class Item(val index: Int, val text: String, val createdAtMillis: Long)
    private data class HistoryItem(val index: Int, val title: String)

    // ---- truncate ----

    @Test
    fun truncateKeepsShortTextUnchanged() {
        assertEquals("hello", MemorySearch.truncate("hello", limit = 10))
        assertEquals("", MemorySearch.truncate("", limit = 10))
    }

    @Test
    fun truncateCutsAtLimit() {
        assertEquals("abc", MemorySearch.truncate("abcdef", limit = 3))
    }

    // ---- rank ----

    @Test
    fun rankPrefersKeywordOverlap() {
        val base = 1_000_000_000L
        val items = listOf(
            Item(0, "周末去爬山的装备清单", base),
            Item(1, "SwiftUI 布局笔记", base + 60_000),
            Item(2, "爬山路线图与注意事项", base + 120_000),
        )
        val ranked = MemorySearch.rank(
            "爬山要带什么", items, limit = 2,
            haystack = { it.text }, createdAtMillis = { it.createdAtMillis },
        )
        assertEquals(2, ranked.size)
        // 两条含"爬山"的排前面,不含的被挤掉
        assertEquals(setOf(0, 2), ranked.map { it.index }.toSet())
    }

    @Test
    fun rankFallsBackToRecency() {
        val base = 1_000_000_000L
        val items = listOf(
            Item(0, "旧条目", base),
            Item(1, "新条目", base + 60_000),
        )
        // 无任何命中时按创建时间倒序兜底
        val ranked = MemorySearch.rank(
            "quantum", items, limit = 2,
            haystack = { it.text }, createdAtMillis = { it.createdAtMillis },
        )
        assertEquals(listOf(1, 0), ranked.map { it.index })
    }

    @Test
    fun rankRespectsLimit() {
        val items = (0 until 30).map { Item(it, "记忆 $it", 0L) }
        val ranked = MemorySearch.rank(
            "记忆", items, limit = MemorySearch.MAX_ASK_ITEMS,
            haystack = { it.text }, createdAtMillis = { it.createdAtMillis },
        )
        assertEquals(MemorySearch.MAX_ASK_ITEMS, ranked.size)
    }

    // ---- rankTaskHistory ----

    @Test
    fun rankTaskHistoryPrefersScoreOrder() {
        val items = listOf(
            HistoryItem(0, "交材料给行政"),
            HistoryItem(1, "开周会"),
            HistoryItem(2, "交材料复印件"),
        )
        val matched = MemorySearch.rankTaskHistory(
            "上次交材料是什么时候", items, limit = 10, haystack = { it.title })
        assertEquals(setOf(0, 2), matched.map { it.index }.toSet())
        assertFalse(matched.any { it.index == 1 })
    }

    /** 与 rank(:) 不同,零命中时不拿近期条目填充,直接返回空。 */
    @Test
    fun rankTaskHistoryReturnsEmptyWithoutRecencyPadding() {
        val items = listOf(HistoryItem(0, "旧条目"), HistoryItem(1, "新条目"))
        val matched = MemorySearch.rankTaskHistory("quantum", items, limit = 10, haystack = { it.title })
        assertTrue(matched.isEmpty())
    }

    @Test
    fun rankTaskHistoryRespectsLimit() {
        val items = (0 until 30).map { HistoryItem(it, "交材料 $it") }
        val matched = MemorySearch.rankTaskHistory("交材料", items, limit = 5, haystack = { it.title })
        assertEquals(5, matched.size)
    }

    // ---- tokens ----

    @Test
    fun tokensMixedLanguage() {
        val terms = MemorySearch.tokens("SwiftUI 手势")
        assertTrue(terms.contains("swiftui"))
        assertTrue(terms.contains("手势"))
    }
}
