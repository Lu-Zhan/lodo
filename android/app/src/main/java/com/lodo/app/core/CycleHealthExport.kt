package com.lodo.app.core

import java.time.LocalDate

/** 与 iOS CycleHealthExport 同口径。Health Connect 无 NONE 档位,无出血以不写流量表示。 */
object CycleHealthExport {
    data class Day(val dayKey: String, val level: CycleFlowLevel)
    data class Existing(val id: String, val day: Day)
    data class Plan(val delete: List<String>, val add: List<Day>)

    fun desired(manual: List<CyclePeriod>, flows: List<CycleFlow.ManualEntry>, foreignDays: Set<String>,
                since: LocalDate, today: LocalDate, openLimit: Int): Map<String, Day> {
        val levels = CycleFlow.resolve(flows, emptyList())
        val result = linkedMapOf<String, Day>()
        for (period in CyclePlan.merge(manual.filterNot { it.fromHealth }, emptyList(), today)) {
            val last = minOf(period.end ?: period.start.plusDays(maxOf(openLimit, 1).toLong() - 1), today)
            var day = maxOf(period.start, since)
            while (day <= last) {
                val key = day.toString()
                val level = levels[key]?.level ?: CycleFlowLevel.UNSPECIFIED
                if (key !in foreignDays && level != CycleFlowLevel.NONE) result.putIfAbsent(key, Day(key, level))
                day = day.plusDays(1)
            }
        }
        return result
    }

    fun plan(desired: Map<String, Day>, existing: List<Existing>): Plan {
        val delete = mutableListOf<String>()
        val add = mutableListOf<Day>()
        val grouped = existing.groupBy { it.day.dayKey }
        for ((key, samples) in grouped) {
            val want = desired[key]
            val keep = samples.sortedBy { it.id }.firstOrNull { it.day == want }
            delete += samples.filter { it != keep }.map { it.id }
            if (want != null && keep == null) add += want
        }
        add += desired.filterKeys { it !in grouped }.values
        return Plan(delete.sorted(), add.sortedBy { it.dayKey })
    }
}
