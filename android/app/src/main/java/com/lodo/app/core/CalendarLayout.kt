package com.lodo.app.core

/**
 * 时间轴上重叠日程的分列(同 iOS CalendarViewPlan 的分列思路):按开始时间排,每条放进第一个
 * 已经空出来的列;互相连着重叠的一簇共用同一个列数,宽度按列数平分。时间用当天的分钟数。
 */
object CalendarLayout {
    data class Slot(val index: Int, val column: Int, val columns: Int)

    fun columns(spans: List<Pair<Int, Int>>): List<Slot> {
        val order = spans.indices.sortedWith(compareBy({ spans[it].first }, { -spans[it].second }))
        val column = IntArray(spans.size)
        val count = IntArray(spans.size)
        var cluster = mutableListOf<Int>()
        var clusterEnd = Int.MIN_VALUE
        val colEnds = mutableListOf<Int>()
        fun close() {
            val n = (cluster.maxOfOrNull { column[it] } ?: -1) + 1
            cluster.forEach { count[it] = n }
            cluster = mutableListOf()
            colEnds.clear()
        }
        for (i in order) {
            val (s, e0) = spans[i]
            val e = maxOf(e0, s + 15)          // 太短的也按 15 分钟占位,免得叠成一条线
            if (cluster.isNotEmpty() && s >= clusterEnd) close()
            val free = colEnds.indexOfFirst { it <= s }
            val col = if (free >= 0) free else colEnds.size
            if (col == colEnds.size) colEnds += e else colEnds[col] = e
            column[i] = col
            cluster += i
            clusterEnd = maxOf(clusterEnd.takeIf { cluster.size > 1 } ?: e, e)
        }
        if (cluster.isNotEmpty()) close()
        return spans.indices.map { Slot(it, column[it], maxOf(1, count[it])) }
    }
}
