package com.lodo.app.core

import java.time.LocalDate

enum class CycleFlowLevel(val raw: String, val rank: Int) {
    NONE("none", 0), LIGHT("light", 1), MEDIUM("medium", 2), HEAVY("heavy", 3), UNSPECIFIED("unspecified", -1);
    val isBleeding get() = this != NONE
    companion object {
        val selectable = listOf(NONE, LIGHT, MEDIUM, HEAVY)
        fun from(raw: String) = entries.firstOrNull { it.raw == raw }
    }
}
object CycleFlow {
    data class ManualEntry(val uuid: String, val dayKey: String, val levelRaw: String, val updatedAtMillis: Long, val isDeleted: Boolean = false)
    data class HealthSample(val dayKey: String, val level: CycleFlowLevel)
    enum class Source { MANUAL, HEALTH }
    data class Day(val level: CycleFlowLevel?, val raw: String, val source: Source, val conflict: Boolean = false)
    fun resolve(manual: List<ManualEntry>, health: List<HealthSample>): Map<String, Day> {
        val result = mutableMapOf<String, Day>()
        for ((key, samples) in health.groupBy { it.dayKey }) {
            val levels = samples.map { it.level }
            val level = levels.filter { it.rank > 0 }.maxByOrNull { it.rank }
                ?: if (CycleFlowLevel.UNSPECIFIED in levels) CycleFlowLevel.UNSPECIFIED else CycleFlowLevel.NONE
            result[key] = Day(level, level.raw, Source.HEALTH, CycleFlowLevel.NONE in levels && levels.any { it.isBleeding })
        }
        for ((key, values) in manual.groupBy { it.dayKey }) {
            val latest = values.maxWith(compareBy<ManualEntry> { it.updatedAtMillis }.thenBy { it.uuid })
            if (!latest.isDeleted) result[key] = Day(CycleFlowLevel.from(latest.levelRaw), latest.levelRaw, Source.MANUAL)
        }
        return result
    }
    fun date(key: String): LocalDate? = if (!Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}").matches(key)) null
        else runCatching { LocalDate.parse(key) }.getOrNull()
    fun dayKeys(start: LocalDate, through: LocalDate): List<String> =
        generateSequence(start) { it.plusDays(1) }.takeWhile { it <= through }.take(60).map { it.toString() }.toList()
}
