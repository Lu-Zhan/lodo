package com.lodo.app.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.pow

/** 不算排卵/易孕期,不用于避孕。日期均为记录地的公历日期。 */
data class CyclePeriod(val id: String, val start: LocalDate, val end: LocalDate? = null, val fromHealth: Boolean = false)

object CyclePlan {
    fun periodsFromFlowDays(days: List<LocalDate>): List<CyclePeriod> {
        val result = mutableListOf<CyclePeriod>()
        for (day in days.distinct().sorted()) {
            val last = result.lastOrNull()
            if (last != null && ChronoUnit.DAYS.between(last.end, day) <= 2) result[result.lastIndex] = last.copy(end = day)
            else result += CyclePeriod("health-$day", day, day, true)
        }
        return result
    }
    fun merge(manual: List<CyclePeriod>, health: List<CyclePeriod>, today: LocalDate): List<CyclePeriod> {
        fun normalized(p: CyclePeriod) = p.copy(end = p.end?.let { maxOf(it, p.start) })
        val kept = manual.map(::normalized).groupBy { it.start }.values.map { group ->
            group.sortedWith(compareBy<CyclePeriod> { it.end == null }.thenBy { it.id }).first()
        }
        fun effectiveEnd(p: CyclePeriod): LocalDate = p.end ?: if (ChronoUnit.DAYS.between(p.start, today) >= 10) p.start.plusDays(4) else maxOf(p.start, today)
        return (kept + health.map(::normalized).filter { h -> kept.none { m -> h.start <= effectiveEnd(m) && m.start <= effectiveEnd(h) } }).sortedBy { it.start }
    }
}

/** 与 iOS CyclePrediction 对齐的加权中位数 + MAD/P80 经验范围。 */
object CyclePrediction {
    const val CANDIDATE_COUNT = 12
    const val SAMPLE_COUNT = 6
    const val DECAY = 0.85
    const val REMINDER_DAYS_BEFORE = 2L
    data class Window(val center: LocalDate, val lower: LocalDate, val upper: LocalDate)
    enum class Evidence { LOW, MEDIUM, HIGH }
    enum class ExclusionReason { OUT_OF_RANGE, LIKELY_SKIPPED }
    data class Interval(val start: LocalDate, val length: Int, val periodLength: Int?, val excluded: ExclusionReason? = null)
    enum class Phase { NO_RECORDS, IN_PERIOD, END_UNCONFIRMED, INSUFFICIENT, BEFORE, IN_WINDOW, LATE }
    data class Confirmations(val notStartedThrough: LocalDate? = null, val ongoingThrough: LocalDate? = null)
    data class Result(
        val phase: Phase = Phase.NO_RECORDS, val day: Int = 0, val lateDays: Int = 0,
        val lastStart: LocalDate? = null, val nextStart: Window? = null, val nextEnd: Window? = null,
        val currentEnd: Window? = null, val daysUntilStart: Int? = null, val daysUntilEnd: Int? = null,
        val cycleLength: Int? = null, val periodLength: Int = 5, val periodLengthIsDefault: Boolean = true,
        val endSamples: Int = 0, val startEvidence: Evidence? = null, val endEvidence: Evidence = Evidence.LOW,
        val stable: Boolean? = null, val validCycles: Int = 0, val cycleRange: IntRange? = null,
        val skippedCount: Int = 0, val intervals: List<Interval> = emptyList(), val lastIntervalLength: Int? = null,
        val canRemind: Boolean = false, val startRevised: Boolean = false,
        val originalNextStart: Window? = null, val endRevised: Boolean = false,
    )
    private fun days(a: LocalDate, b: LocalDate) = ChronoUnit.DAYS.between(a, b).toInt()
    private fun LocalDate.add(days: Int) = plusDays(days.toLong())

    fun predict(periods: List<CyclePeriod>, today: LocalDate, confirmations: Confirmations = Confirmations()): Result {
        val past = periods.map { it.copy(end = it.end?.let { e -> maxOf(it.start, e) }) }.filter { it.start <= today }.sortedBy { it.start }
        val last = past.lastOrNull() ?: return Result()
        val intervals = past.zipWithNext().map { (a, b) ->
            Interval(a.start, days(a.start, b.start), if (a.fromHealth) null else a.end?.let { days(a.start, it) + 1 })
        }.toMutableList()
        var candidates = intervals.indices.toList().takeLast(CANDIDATE_COUNT).filter { intervals[it].start.add(intervals[it].length) >= today.minusMonths(24) }
        for (i in candidates) if (intervals[i].length !in 15..90) intervals[i] = intervals[i].copy(excluded = ExclusionReason.OUT_OF_RANGE)
        candidates = candidates.filter { intervals[it].excluded == null }
        val lengths = candidates.map { intervals[it].length }
        median(lengths.map { it.toDouble() })?.let { m ->
            if (lengths.count { abs(it - m) <= maxOf(3.0, 0.15 * m) } >= 3) for (i in candidates) {
                val length = intervals[i].length.toDouble()
                if (length >= 1.7 * m && listOf(2.0, 3.0).any { abs(length / it - m) <= maxOf(2.0, 0.10 * m) })
                    intervals[i] = intervals[i].copy(excluded = ExclusionReason.LIKELY_SKIPPED)
            }
        }
        val skippedCount = candidates.count { intervals[it].excluded == ExclusionReason.LIKELY_SKIPPED }
        val recentSkipped = intervals.takeLast(SAMPLE_COUNT).count { it.excluded == ExclusionReason.LIKELY_SKIPPED }
        val valid = candidates.filter { intervals[it].excluded == null }.takeLast(SAMPLE_COUNT).reversed().map { intervals[it].length }
        val periodLengths = past.filter { !it.fromHealth }.mapNotNull { p -> p.end?.takeIf { it <= today }?.let { days(p.start, it) + 1 } }
            .filter { it in 1..14 }.takeLast(SAMPLE_COUNT).reversed()
        val periodLength = if (periodLengths.isEmpty()) 5 else weightedMedian(periodLengths)
        val periodSpread = if (periodLengths.isEmpty()) 3 else spread(periodLengths, periodLength, if (periodLengths.size <= 2) 2 else 1)
        val endEvidence = if (periodLengths.size >= 3 && periodSpread <= 2) Evidence.HIGH else if (periodLengths.isEmpty()) Evidence.LOW else Evidence.MEDIUM
        val sinceStart = days(last.start, today)
        var predictedEnd = Window(last.start.add(periodLength - 1), last.start.add(maxOf(1, periodLength - periodSpread) - 1), last.start.add(periodLength + periodSpread - 1))
        var endRevised = false
        var ongoingThrough: LocalDate? = null
        confirmations.ongoingThrough?.takeIf { it >= last.start && it <= today && (last.fromHealth || last.end == null) }?.let { d ->
            ongoingThrough = d
            val elapsed = days(last.start, d) + 1
            val lower = d.add(1)
            val longer = periodLengths.filter { it > elapsed }
            val center = if (longer.isEmpty()) lower else maxOf(lower, last.start.add(weightedMedian(longer) - 1))
            predictedEnd = Window(center, lower, maxOf(predictedEnd.upper, center, if (longer.isEmpty()) lower.add(1) else center))
            endRevised = true
        }
        var phase: Phase? = null
        var currentEnd: Window? = null
        if (!last.fromHealth) {
            if (last.end != null) {
                if (today <= last.end) { phase = Phase.IN_PERIOD; currentEnd = Window(last.end, last.end, last.end) }
            } else {
                phase = if (today <= predictedEnd.upper) Phase.IN_PERIOD else Phase.END_UNCONFIRMED
                currentEnd = predictedEnd
            }
        } else {
            val observed = listOfNotNull(last.end, ongoingThrough).maxOrNull()
            if (observed != null && today <= observed.add(1) && today <= predictedEnd.upper) { phase = Phase.IN_PERIOD; currentEnd = predictedEnd }
        }
        if (endRevised && phase == null) endRevised = false
        val daysUntilEnd = if (phase == Phase.IN_PERIOD) currentEnd?.let { days(today, it.center) } else null
        var nextStart: Window? = null
        var nextEnd: Window? = null
        var startEvidence: Evidence? = null
        var cycleLength: Int? = null
        var stable: Boolean? = null
        var canRemind = false
        fun endWindow(start: Window) = Window(start.center.add(periodLength - 1), start.lower.add(maxOf(1, periodLength - periodSpread) - 1), start.upper.add(periodLength + periodSpread - 1))
        if (valid.size >= 2) {
            val c = weightedMedian(valid)
            cycleLength = c
            val w = spread(valid, c, if (valid.size == 2) 7 else if (valid.size <= 4) 4 else 2)
            val center = last.start.add(c)
            nextStart = Window(center, maxOf(last.start.add(1), center.add(-w)), center.add(w))
            nextEnd = endWindow(nextStart)
            if (valid.size >= 3) {
                val m = median(valid.map { it.toDouble() }) ?: c.toDouble()
                val mad = median(valid.map { abs(it - m) }) ?: 0.0
                stable = mad <= 2 && valid.max() - valid.min() <= 7
            }
            startEvidence = if (valid.size == 2 || w > 7 || sinceStart > 90) Evidence.LOW
                else if (valid.size >= 5 && w <= 4 && recentSkipped <= 1) Evidence.HIGH else Evidence.MEDIUM
            canRemind = valid.size >= 3 && startEvidence != Evidence.LOW && w <= 7
        }
        val originalNextStart = nextStart
        var startRevised = false
        val d = confirmations.notStartedThrough
        if (phase == null && originalNextStart != null && d != null && d > last.start && d <= today && d >= originalNextStart.lower) {
            val elapsed = days(last.start, d)
            val lower = d.add(1)
            val longer = valid.filter { it > elapsed }
            val center: LocalDate
            val upper: LocalDate
            if (longer.isEmpty()) {
                val w = spread(valid, cycleLength ?: elapsed, 2).coerceIn(2, 7)
                upper = maxOf(originalNextStart.upper, lower.add(w))
                center = lower.add(w / 2)
            } else {
                center = maxOf(lower, last.start.add(weightedMedian(longer)))
                upper = maxOf(originalNextStart.upper, center)
            }
            nextStart = Window(center, lower, upper); nextEnd = endWindow(nextStart); startRevised = true; canRemind = false
        }
        var late = 0
        if (phase == null) {
            val next = nextStart
            phase = when {
                next == null -> Phase.INSUFFICIENT
                startRevised && originalNextStart != null && today > originalNextStart.upper -> { late = days(originalNextStart.upper, today); Phase.LATE }
                today > next.upper -> { late = days(next.upper, today); Phase.LATE }
                today >= next.lower -> Phase.IN_WINDOW
                else -> Phase.BEFORE
            }
        }
        return Result(phase, sinceStart + 1, late, last.start, nextStart, nextEnd, currentEnd,
            nextStart?.let { days(today, it.center) }, daysUntilEnd, cycleLength, periodLength, periodLengths.isEmpty(), periodLengths.size,
            startEvidence, endEvidence, stable, valid.size, if (valid.isEmpty()) null else valid.min()..valid.max(), skippedCount,
            intervals.reversed(), intervals.singleOrNull()?.length, canRemind, startRevised, originalNextStart, endRevised)
    }

    fun reminderDate(result: Result, time: String, now: LocalDateTime): LocalDateTime? {
        if (!result.canRemind) return null
        val lower = result.nextStart?.lower ?: return null
        val at = runCatching { lower.minusDays(REMINDER_DAYS_BEFORE).atTime(LocalTime.parse(time)) }.getOrNull() ?: return null
        return at.takeIf { it > now }
    }
    internal fun weightedMedian(values: List<Int>): Int {
        val weighted = values.mapIndexed { i, v -> v to DECAY.pow(i) }
        val half = weighted.sumOf { it.second } / 2
        var acc = 0.0
        for ((value, weight) in weighted.sortedBy { it.first }) { acc += weight; if (acc >= half - 1e-9) return value }
        return values.firstOrNull() ?: 0
    }
    internal fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val s = values.sorted(); val mid = s.size / 2
        return if (s.size % 2 == 1) s[mid] else (s[mid - 1] + s[mid]) / 2
    }
    internal fun spread(values: List<Int>, center: Int, floor: Int): Int {
        val m = median(values.map { it.toDouble() }) ?: center.toDouble()
        val mad = median(values.map { abs(it - m) }) ?: 0.0
        val deviations = values.map { abs(it - center).toDouble() }.sorted()
        val rank = maxOf(1, ceil(0.8 * deviations.size).toInt())
        val p80 = if (deviations.isEmpty()) 0.0 else deviations[minOf(rank, deviations.size) - 1]
        return ceil(maxOf(floor.toDouble(), 2 * 1.4826 * mad, p80)).toInt()
    }
}
