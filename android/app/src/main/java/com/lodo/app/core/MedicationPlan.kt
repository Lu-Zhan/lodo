package com.lodo.app.core

import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime

object MedicationPlan {
    enum class Status(val raw: String) { TAKEN("taken"), SKIPPED("skipped") }
    data class Med(val id: String, val name: String, val dosage: String = "", val times: List<String> = emptyList(), val days: List<Int> = emptyList(), val archived: Boolean = false)
    data class Dose(val id: String, val medicationId: String?, val takenAt: LocalDateTime, val status: Status = Status.TAKEN, val healthSampleId: String? = null)
    enum class SlotState { TAKEN, SKIPPED, UPCOMING, DUE }
    data class Slot(val medicationId: String, val name: String, val dosage: String, val time: LocalDateTime, val state: SlotState, val takenAt: LocalDateTime? = null)
    fun isScheduled(med: Med, day: LocalDate) = !med.archived && med.times.isNotEmpty() && (med.days.isEmpty() || day.dayOfWeek.value - 1 in med.days)
    fun todaySlots(meds: List<Med>, doses: List<Dose>, now: LocalDateTime): List<Slot> {
        val day = now.toLocalDate()
        return meds.filter { isScheduled(it, day) }.flatMap { med ->
            val times = med.times.distinct().sorted().mapNotNull { runCatching { day.atTime(java.time.LocalTime.parse(it)) }.getOrNull() }
            val today = doses.filter { it.medicationId == med.id && it.takenAt.toLocalDate() == day }.sortedBy { it.takenAt }
            times.mapIndexed { index, time ->
                val dose = today.getOrNull(index)
                val state = if (dose != null) { if (dose.status == Status.TAKEN) SlotState.TAKEN else SlotState.SKIPPED }
                    else if (time > now) SlotState.UPCOMING else SlotState.DUE
                Slot(med.id, med.name, med.dosage, time, state, dose?.takenAt)
            }
        }.sortedWith(compareBy<Slot> { it.time }.thenBy { it.name })
    }
    fun nextUnrecordedSlot(id: String, slots: List<Slot>) = slots.firstOrNull { it.medicationId == id && it.state in setOf(SlotState.UPCOMING, SlotState.DUE) }
    fun isEarly(slot: Slot, now: LocalDateTime) = Duration.between(now, slot.time).seconds > 3600
    fun nextDose(med: Med, after: LocalDateTime): LocalDateTime? = Scheduler.nextOccurrence(TaskData(
        med.name, after, repeatType = if (med.days.isEmpty()) RepeatType.DAILY else RepeatType.WEEKLY,
        repeatDays = med.days.distinct().sorted(), repeatTimes = med.times.distinct().sorted()), after)
    fun shouldImport(sampleId: String, medicationId: String, takenAt: LocalDateTime, existing: List<Dose>) = existing.none {
        it.healthSampleId == sampleId || (it.medicationId == medicationId && kotlin.math.abs(Duration.between(it.takenAt, takenAt).seconds) < 1800)
    }
    fun adherence(meds: List<Med>, doses: List<Dose>, days: Int, now: LocalDateTime): Pair<Int, Int> {
        var taken = 0; var expected = 0
        for (offset in 0 until days.coerceAtLeast(0)) {
            val day = now.toLocalDate().minusDays(offset.toLong())
            val probe = (if (offset == 0) now else day.plusDays(1).atStartOfDay()).minusSeconds(1)
            for (slot in todaySlots(meds, doses, probe)) when (slot.state) {
                SlotState.TAKEN -> { taken++; expected++ }
                SlotState.SKIPPED, SlotState.DUE -> expected++
                SlotState.UPCOMING -> Unit
            }
        }
        return taken to expected
    }
}
