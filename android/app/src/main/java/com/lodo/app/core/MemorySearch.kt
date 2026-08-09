package com.lodo.app.core

/**
 * 记忆检索的纯逻辑部分(截断/关键词打分/待办历史匹配),与 iOS LodoCore
 * MemorySearch.swift 对齐——iOS 还有基于端上 embedding 的语义检索,Android
 * 这一轮没有对应的端上 embedding 基础设施,退化成纯关键词版本;这与 iOS
 * "没有 embedding 时退化成关键词搜索"是同一个合法降级路径,不是残缺实现。
 * 不引 Android/Room 依赖,保持纯 Kotlin/JVM 可单测(与 Scheduler 同一个约定)。
 */
object MemorySearch {
    const val MAX_SOURCE_CHARS = 8000
    const val MAX_EXCERPT_CHARS = 400
    const val MAX_ASK_ITEMS = 20
    const val MAX_HISTORY_ITEMS = 10

    fun truncate(text: String, limit: Int = MAX_SOURCE_CHARS): String =
        if (text.length <= limit) text else text.take(limit)

    /** 按 token 重合数打分,分高优先、同分按新旧排;命中数不足 limit 时用最新
     * 条目补足,保证 AI 手头总有一些上下文(与 iOS MemorySearch.rank 一致)。 */
    fun <T> rank(
        question: String, items: List<T>, limit: Int,
        haystack: (T) -> String, createdAtMillis: (T) -> Long,
    ): List<T> {
        if (items.isEmpty()) return emptyList()
        val qTokens = tokens(question)
        val byRecency = items.sortedByDescending(createdAtMillis)
        if (qTokens.isEmpty()) return byRecency.take(limit)
        val scored = byRecency.map { item -> item to qTokens.count { tokens(haystack(item)).contains(it) } }
        val hit = scored.filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<T, Int>> { it.second }.thenByDescending { createdAtMillis(it.first) })
            .map { it.first }
        if (hit.size >= limit) return hit.take(limit)
        val padding = scored.filter { it.second == 0 }.map { it.first }.take(limit - hit.size)
        return hit + padding
    }

    /** 待办历史匹配:只返回真正命中关键词的,不做"补足"兜底——找不到就是
     * 没有,不能硬凑最近完成的事项充数,那会让"上次做过 X 吗"这类问题被
     * 误导性回答(与 iOS matchTaskHistory 一致)。 */
    fun <T> rankTaskHistory(
        question: String, items: List<T>, limit: Int, haystack: (T) -> String,
    ): List<T> {
        val qTokens = tokens(question)
        if (qTokens.isEmpty()) return emptyList()
        return items
            .map { it to qTokens.count { t -> tokens(haystack(it)).contains(t) } }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
            .take(limit)
            .map { it.first }
    }

    /** 字母数字词(≥2 字符)+ 中文按 2 字滑窗切分,与 iOS tokens(_:) 同一个思路。 */
    fun tokens(text: String): Set<String> {
        val lower = text.lowercase()
        val result = mutableSetOf<String>()
        Regex("[a-z0-9]{2,}").findAll(lower).forEach { result += it.value }
        Regex("[\\u4e00-\\u9fff]+").findAll(lower).forEach { run ->
            val s = run.value
            if (s.length == 1) {
                result += s
            } else {
                for (i in 0 until s.length - 1) result += s.substring(i, i + 2)
            }
        }
        return result
    }
}
