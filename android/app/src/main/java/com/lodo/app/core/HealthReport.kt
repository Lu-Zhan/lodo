package com.lodo.app.core

import java.time.LocalDate
import java.util.Locale
import kotlin.math.abs

/** 健康指标,存储/顺序与 iOS HealthMetricKind 一致。 */
enum class HealthMetricKind(val raw: String, val promptName: String, val promptUnit: String, val fractionDigits: Int, val higherIsBetter: Boolean) {
    STEPS("steps", "步数", "步", 0, true),
    ACTIVE_ENERGY("activeEnergy", "活动能量", "千卡", 0, true),
    EXERCISE_MINUTES("exerciseMinutes", "锻炼时长", "分钟", 0, true),
    SLEEP_HOURS("sleepHours", "睡眠时长", "小时", 1, true),
    RESTING_HEART_RATE("restingHeartRate", "静息心率", "次/分", 0, false),
    HRV("hrv", "心率变异性", "毫秒", 0, true),
    BODY_MASS("bodyMass", "体重", "公斤", 1, false);

    fun format(value: Double): String = String.format(Locale.ROOT, "%.${fractionDigits}f", value)
}

data class HealthDailyPoint(val date: LocalDate, val value: Double)

data class HealthSeries(val kind: HealthMetricKind, val points: List<HealthDailyPoint>)

/**
 * 健康报告纯逻辑,同 iOS HealthReport:均值、最近一天、"最近 7 天 vs 之前 7 天"的趋势、
 * 喂给 AI 的汇总(只发汇总统计,逐条原始样本不出数据层)。
 */
data class HealthReport(val series: List<HealthSeries>, val rangeDays: Int) {
    val isEmpty get() = series.none { it.points.isNotEmpty() }

    fun series(kind: HealthMetricKind) = series.firstOrNull { it.kind == kind }?.takeIf { it.points.isNotEmpty() }

    fun average(kind: HealthMetricKind): Double? = series(kind)?.points?.map { it.value }?.average()

    fun latest(kind: HealthMetricKind): Double? = series(kind)?.points?.maxByOrNull { it.date }?.value

    fun trend(kind: HealthMetricKind, window: Int = 7): Double? {
        val points = series(kind)?.points?.sortedBy { it.date } ?: return null
        if (points.size <= window) return null
        val recent = points.takeLast(window)
        val earlier = points.dropLast(window).takeLast(window)
        if (earlier.isEmpty()) return null
        val r = recent.map { it.value }.average()
        val e = earlier.map { it.value }.average()
        if (e == 0.0) return null
        return (r - e) / e
    }

    fun promptSummary(): String {
        if (isEmpty) return ""
        val lines = mutableListOf("最近 $rangeDays 天的健康数据:")
        for (s in series.filter { it.points.isNotEmpty() }) {
            val k = s.kind
            var line = "- ${k.promptName}:日均 ${k.format(average(k) ?: 0.0)} ${k.promptUnit}"
            latest(k)?.let { line += ",最近一天 ${k.format(it)} ${k.promptUnit}" }
            trend(k)?.let { t ->
                val pct = String.format(Locale.ROOT, "%.0f", abs(t) * 100)
                line += if (t >= 0) ",较上一周期上升 $pct%" else ",较上一周期下降 $pct%"
            }
            lines += line
        }
        return lines.joinToString("\n")
    }

    companion object {
        val EMPTY = HealthReport(emptyList(), 0)
    }
}
