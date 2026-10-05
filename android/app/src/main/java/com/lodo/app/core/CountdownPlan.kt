package com.lodo.app.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import kotlin.math.abs

/** 倒数日的值快照,对应 iOS CountdownEntry;CountdownPlan 只认这个。 */
data class CountdownEntry(
    val id: String,
    val title: String,
    val start: LocalDateTime,
    val end: LocalDateTime? = null,
    val allDay: Boolean = true,
    val startReminders: List<Int> = emptyList(),
    val endReminders: List<Int> = emptyList(),
    val showInWidget: Boolean = false,
    val archived: Boolean = false,
)

/** 离某个节点多久,对应 iOS CountdownSpan。 */
data class CountdownSpan(val milestone: Milestone, val days: Int, val minutes: Int? = null) {
    enum class Milestone { UNTIL_START, SINCE_START, UNTIL_END, SINCE_END }
}

data class CountdownReminder(
    val eventId: String, val title: String, val fireAt: LocalDateTime,
    val isEnd: Boolean, val offsetMinutes: Int,
)

/** 纯逻辑,与 iOS CountdownPlan 逐条同义(全天按日子算、结束那天整天都算进行中…)。 */
object CountdownPlan {
    const val WIDGET_LIMIT = 3
    val reminderPresets = listOf(0, 5, 15, 30, 60, 120, 1440, 2880, 10080)

    fun spans(entry: CountdownEntry, now: LocalDateTime): List<CountdownSpan> {
        val today = now.toLocalDate()
        val startMoment = if (entry.allDay) entry.start.toLocalDate().atStartOfDay() else entry.start
        val endMoment = entry.end?.let { end ->
            if (entry.allDay) end.toLocalDate().plusDays(1).atStartOfDay() else end
        }
        fun dayDiff(date: LocalDateTime) = abs(ChronoUnit.DAYS.between(today, date.toLocalDate()).toInt())
        fun span(m: CountdownSpan.Milestone, moment: LocalDateTime, dayOf: LocalDateTime): CountdownSpan {
            val days = dayDiff(dayOf)
            val minutes = if (!entry.allDay && days == 0) {
                abs(ChronoUnit.SECONDS.between(now, moment) / 60).toInt()
            } else null
            return CountdownSpan(m, days, minutes)
        }
        if (now.isBefore(startMoment)) return listOf(span(CountdownSpan.Milestone.UNTIL_START, startMoment, entry.start))
        val end = entry.end
        if (endMoment == null || end == null) return listOf(span(CountdownSpan.Milestone.SINCE_START, startMoment, entry.start))
        if (now.isBefore(endMoment)) {
            return listOf(
                span(CountdownSpan.Milestone.UNTIL_END, endMoment, end),
                span(CountdownSpan.Milestone.SINCE_START, startMoment, entry.start),
            )
        }
        return listOf(span(CountdownSpan.Milestone.SINCE_END, endMoment, end))
    }

    fun primary(entry: CountdownEntry, now: LocalDateTime) = spans(entry, now)[0]

    fun isPast(entry: CountdownEntry, now: LocalDateTime): Boolean {
        val span = primary(entry, now)
        return when (span.milestone) {
            CountdownSpan.Milestone.SINCE_END -> true
            CountdownSpan.Milestone.SINCE_START -> !(entry.allDay && span.days == 0)
            else -> false
        }
    }

    fun sorted(entries: List<CountdownEntry>, now: LocalDateTime): List<CountdownEntry> {
        fun next(e: CountdownEntry) = if (now.isBefore(e.start)) e.start else (e.end ?: e.start)
        fun last(e: CountdownEntry) = e.end ?: e.start
        val upcoming = entries.filter { !isPast(it, now) }.sortedBy { next(it) }
        val past = entries.filter { isPast(it, now) }.sortedByDescending { last(it) }
        return upcoming + past
    }

    fun widgetEntries(entries: List<CountdownEntry>, now: LocalDateTime): List<CountdownEntry> =
        sorted(entries.filter { it.showInWidget && !it.archived }, now).take(WIDGET_LIMIT)

    fun reminders(entries: List<CountdownEntry>, allDayTime: String, now: LocalDateTime): List<CountdownReminder> {
        val time = parseTime(allDayTime)
        fun base(date: LocalDateTime, allDay: Boolean) = if (allDay) date.toLocalDate().atTime(time) else date
        val result = mutableListOf<CountdownReminder>()
        for (e in entries) {
            if (e.archived) continue
            val sb = base(e.start, e.allDay)
            e.startReminders.toSet().forEach { result += CountdownReminder(e.id, e.title, sb.minusMinutes(it.toLong()), false, it) }
            e.end?.let { end ->
                val eb = base(end, e.allDay)
                e.endReminders.toSet().forEach { result += CountdownReminder(e.id, e.title, eb.minusMinutes(it.toLong()), true, it) }
            }
        }
        return result.filter { it.fireAt.isAfter(now) }.sortedWith(compareBy({ it.fireAt }, { it.offsetMinutes }))
    }

    sealed interface MilestoneKind {
        data object Start : MilestoneKind
        data class Anniversary(val years: Int) : MilestoneKind
        data class DayCount(val days: Int) : MilestoneKind
    }

    data class Milestone(val kind: MilestoneKind, val date: LocalDate, val daysAway: Int)

    fun milestones(entry: CountdownEntry, now: LocalDateTime, horizonDays: Int = 60): List<Milestone> {
        val today = now.toLocalDate()
        val startDay = entry.start.toLocalDate()
        fun days(to: LocalDate) = ChronoUnit.DAYS.between(today, to).toInt()
        val result = mutableListOf<Milestone>()
        if (startDay.isAfter(today)) {
            result += Milestone(MilestoneKind.Start, startDay, days(startDay))
        } else {
            val passed = ChronoUnit.YEARS.between(startDay, today).toInt()
            for (years in listOf(passed, passed + 1)) {
                if (years < 1) continue
                val date = startDay.plusYears(years.toLong())
                if (!date.isBefore(today)) {
                    result += Milestone(MilestoneKind.Anniversary(years), date, days(date))
                    break
                }
            }
            val elapsed = ChronoUnit.DAYS.between(startDay, today).toInt()
            val next = maxOf(100, if (elapsed % 100 == 0) elapsed else (elapsed / 100 + 1) * 100)
            result += Milestone(MilestoneKind.DayCount(next), startDay.plusDays(next.toLong()), next - elapsed)
        }
        return result.filter { it.daysAway <= horizonDays }.sortedBy { it.daysAway }
    }

    data class CountUp(val entry: CountdownEntry, val next: Milestone?)

    fun countUps(entries: List<CountdownEntry>, now: LocalDateTime): List<CountUp> {
        val past = sorted(entries.filter { !it.archived && isPast(it, now) }, now)
        val items = past.map { e ->
            CountUp(e, if (e.end == null) milestones(e, now, 366).firstOrNull() else null)
        }
        val order = items.mapIndexed { i, c -> c.entry.id to i }.toMap()
        return items.sortedWith { a, b ->
            val x = a.next?.daysAway
            val y = b.next?.daysAway
            when {
                x != null && y != null && x != y -> x.compareTo(y)
                x != null && y == null -> -1
                x == null && y != null -> 1
                else -> order.getValue(a.entry.id).compareTo(order.getValue(b.entry.id))
            }
        }
    }

    /** 给 AI 写"今日一句"的素材,固定中文,同 iOS promptSummary。 */
    fun promptSummary(entries: List<CountdownEntry>, now: LocalDateTime): String {
        val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        return sorted(entries.filter { !it.archived }, now).joinToString("\n") { e ->
            val span = primary(e, now)
            var line = "「${e.title}」${e.start.format(fmt)}"
            e.end?.let { line += " 至 ${it.format(fmt)}" }
            line += when (span.milestone) {
                CountdownSpan.Milestone.UNTIL_START -> ",还有 ${span.days} 天开始"
                CountdownSpan.Milestone.UNTIL_END -> ",进行中,还有 ${span.days} 天结束"
                CountdownSpan.Milestone.SINCE_START -> ",已经 ${span.days} 天"
                CountdownSpan.Milestone.SINCE_END -> ",已结束 ${span.days} 天"
            }
            val upcoming = milestones(e, now).mapNotNull { m ->
                val whenText = if (m.daysAway == 0) "今天" else "${m.daysAway} 天后"
                when (val k = m.kind) {
                    MilestoneKind.Start -> null
                    is MilestoneKind.Anniversary -> "${whenText}满 ${k.years} 周年"
                    is MilestoneKind.DayCount -> "${whenText}满 ${k.days} 天"
                }
            }
            if (upcoming.isNotEmpty()) line += ";" + upcoming.joinToString("、")
            line
        }
    }

    fun parseTime(text: String): LocalTime {
        val parts = text.split(":").mapNotNull { it.trim().toIntOrNull() }
        return if (parts.size == 2 && parts[0] in 0..23 && parts[1] in 0..59) LocalTime.of(parts[0], parts[1])
        else LocalTime.of(9, 0)
    }
}
