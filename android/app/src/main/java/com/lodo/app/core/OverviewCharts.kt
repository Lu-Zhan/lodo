package com.lodo.app.core

import java.time.LocalDate

/**
 * 总览圆环/图表模块的纯计算,同 iOS `OverviewCharts.swift`。
 * 活动圆环 = 今天的活动能量/锻炼时长/步数对固定目标的完成度(没接系统健身目标),只认今天的点;
 * 缺数据的日子留空不补 0。
 */
object OverviewCharts {
    /** 固定目标(同 iOS ActivityRingGoal):500 千卡 / 30 分钟 / 8000 步。 */
    val ringGoals = linkedMapOf(
        HealthMetricKind.ACTIVE_ENERGY to 500.0,
        HealthMetricKind.EXERCISE_MINUTES to 30.0,
        HealthMetricKind.STEPS to 8000.0,
    )

    data class Ring(val kind: HealthMetricKind, val value: Double?, val goal: Double) {
        /** 完成度,可以超过 1(超 100% 叠第二圈);没数据为 null。 */
        val progress: Double? get() = value?.let { it / goal }
    }

    fun rings(report: HealthReport, today: LocalDate): List<Ring> = ringGoals.map { (kind, goal) ->
        Ring(kind, report.series(kind)?.points?.firstOrNull { it.date == today }?.value, goal)
    }

    /** 今日进度:今天完成的 / (今天完成的 + 今天还没做的)。一件都没有时为 null(不显示 0%)。 */
    data class Progress(val done: Int, val total: Int) {
        val fraction: Double? get() = if (total == 0) null else done.toDouble() / total
    }

    fun todayProgress(doneToday: Int, pendingToday: Int) = Progress(doneToday, doneToday + pendingToday)

    /** 步数趋势:最近 `days` 天,每天一个值,缺的日子是 null。 */
    fun stepTrend(report: HealthReport, today: LocalDate, days: Int = 7): List<Pair<LocalDate, Double?>> {
        val points = report.series(HealthMetricKind.STEPS)?.points.orEmpty().associate { it.date to it.value }
        return (days - 1 downTo 0).map { today.minusDays(it.toLong()) }.map { it to points[it] }
    }
}
