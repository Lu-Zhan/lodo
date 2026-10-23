package com.lodo.app.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime

class HealthPlanTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)
    private val today = now.toLocalDate()
    private fun periods(gaps: List<Int>, ended: Boolean = true): List<CyclePeriod> {
        var start = LocalDate.of(2026, 1, 1)
        val starts = mutableListOf(start)
        gaps.forEach { start = start.plusDays(it.toLong()); starts += start }
        return starts.mapIndexed { i, d -> CyclePeriod("p$i", d, if (ended) d.plusDays(4) else null) }
    }
    @Test fun noRecords() { assertEquals(CyclePrediction.Phase.NO_RECORDS, CyclePrediction.predict(emptyList(), today).phase) }
    @Test fun futurePeriodsIgnored() { assertEquals(CyclePrediction.Phase.NO_RECORDS, CyclePrediction.predict(listOf(CyclePeriod("a", today.plusDays(1))), today).phase) }
    @Test fun defaultPeriodLength() { assertEquals(5, CyclePrediction.predict(listOf(CyclePeriod("a", today)), today).periodLength) }
    @Test fun unknownEndDoesNotAutoFinish() { assertEquals(CyclePrediction.Phase.END_UNCONFIRMED, CyclePrediction.predict(listOf(CyclePeriod("a", today.minusDays(15))), today).phase) }
    @Test fun actualEndWins() { assertEquals(today.plusDays(1), CyclePrediction.predict(listOf(CyclePeriod("a", today.minusDays(2), today.plusDays(1))), today).currentEnd?.center) }
    @Test fun oneIntervalInsufficient() { assertNull(CyclePrediction.predict(periods(listOf(28)), today).nextStart) }
    @Test fun twoIntervalsGiveLowEvidence() {
        val r = CyclePrediction.predict(periods(listOf(28, 28)), LocalDate.of(2026, 3, 2))
        assertEquals(CyclePrediction.Evidence.LOW, r.startEvidence); assertFalse(r.canRemind)
    }
    @Test fun threeStableIntervalsCanRemind() {
        val p = periods(listOf(28, 28, 28)); val r = CyclePrediction.predict(p, p.last().start.plusDays(8))
        assertTrue(r.canRemind); assertEquals(28, r.cycleLength); assertEquals(true, r.stable)
    }
    @Test fun outOfRangeExcluded() {
        val p = periods(listOf(28, 5, 28, 28)); val r = CyclePrediction.predict(p, p.last().start.plusDays(8))
        assertEquals(3, r.validCycles); assertTrue(r.intervals.any { it.excluded == CyclePrediction.ExclusionReason.OUT_OF_RANGE })
    }
    @Test fun likelySkippedExcluded() {
        val p = periods(listOf(28, 28, 56, 28)); val r = CyclePrediction.predict(p, p.last().start.plusDays(8))
        assertEquals(1, r.skippedCount); assertEquals(3, r.validCycles); assertEquals(28, r.cycleLength)
    }
    @Test fun oldSamplesExpire() { assertEquals(0, CyclePrediction.predict(periods(listOf(28, 28, 28)), today.plusYears(3)).validCycles) }
    @Test fun recentSampleCap() { val p = periods(List(8) { 20 }); assertEquals(6, CyclePrediction.predict(p, p.last().start.plusDays(8)).validCycles) }
    @Test fun reminderAtLowerBoundMinusTwoDays() {
        val p = periods(listOf(28, 28, 28)); val probe = p.last().start.plusDays(8).atTime(9, 0)
        val r = CyclePrediction.predict(p, probe.toLocalDate())
        assertEquals(r.nextStart!!.lower.minusDays(2).atTime(9, 0), CyclePrediction.reminderDate(r, "09:00", probe))
    }
    @Test fun remindersNeverInPast() {
        val p = periods(listOf(28, 28, 28)); val r = CyclePrediction.predict(p, p.last().start.plusDays(8))
        assertNull(CyclePrediction.reminderDate(r, "09:00", today.atTime(9, 0)))
    }
    @Test fun notStartedConfirmationRevisesRangeAndSuppressesReminder() {
        val p = periods(listOf(28, 28, 28)); val probe = p.last().start.plusDays(30)
        val r = CyclePrediction.predict(p, probe, CyclePrediction.Confirmations(notStartedThrough = probe))
        assertTrue(r.startRevised); assertEquals(probe.plusDays(1), r.nextStart!!.lower); assertFalse(r.canRemind)
    }
    @Test fun futureConfirmationIgnored() {
        val p = periods(listOf(28, 28, 28)); val probe = p.last().start.plusDays(26)
        assertFalse(CyclePrediction.predict(p, probe, CyclePrediction.Confirmations(notStartedThrough = probe.plusDays(1))).startRevised)
    }
    @Test fun ongoingConfirmationMovesEarliestEnd() {
        val r = CyclePrediction.predict(listOf(CyclePeriod("a", today.minusDays(7))), today, CyclePrediction.Confirmations(ongoingThrough = today))
        assertTrue(r.endRevised); assertEquals(today.plusDays(1), r.currentEnd!!.lower)
    }
    @Test fun manualOverridesOverlappingHealth() {
        assertEquals(1, CyclePlan.merge(listOf(CyclePeriod("manual", today.minusDays(2), today)), listOf(CyclePeriod("health", today.minusDays(1), today, true)), today).size)
    }
    @Test fun healthFlowDaysMergeAcrossOneBlankDay() { assertEquals(1, CyclePlan.periodsFromFlowDays(listOf(today, today.plusDays(2))).size) }
    @Test fun healthFlowDaysSplitAfterTwoBlankDays() { assertEquals(2, CyclePlan.periodsFromFlowDays(listOf(today, today.plusDays(3))).size) }
    @Test fun manualFlowWins() {
        val r = CycleFlow.resolve(listOf(CycleFlow.ManualEntry("a", today.toString(), "none", 10)), listOf(CycleFlow.HealthSample(today.toString(), CycleFlowLevel.HEAVY)))
        assertEquals(CycleFlowLevel.NONE, r[today.toString()]!!.level); assertEquals(CycleFlow.Source.MANUAL, r[today.toString()]!!.source)
    }
    @Test fun flowTombstoneRevealsHealth() {
        val r = CycleFlow.resolve(listOf(CycleFlow.ManualEntry("a", today.toString(), "none", 10, true)), listOf(CycleFlow.HealthSample(today.toString(), CycleFlowLevel.HEAVY)))
        assertEquals(CycleFlowLevel.HEAVY, r[today.toString()]!!.level)
    }
    @Test fun unknownManualFlowNotTreatedAsNone() { assertNull(CycleFlow.resolve(listOf(CycleFlow.ManualEntry("a", today.toString(), "future", 10)), emptyList())[today.toString()]!!.level) }
    @Test fun conflictingHealthFlowMarked() {
        assertTrue(CycleFlow.resolve(emptyList(), listOf(CycleFlow.HealthSample("2026-07-08", CycleFlowLevel.NONE), CycleFlow.HealthSample("2026-07-08", CycleFlowLevel.LIGHT)))["2026-07-08"]!!.conflict)
    }
    @Test fun flowDateParsingStrict() { assertNull(CycleFlow.date("2026-02-30")); assertNull(CycleFlow.date("2026-7-8")); assertEquals(today, CycleFlow.date("2026-07-08")) }
    @Test fun flowRangeBounded() { assertEquals(60, CycleFlow.dayKeys(today, today.plusDays(100)).size) }
    @Test fun doseScheduleUsesMondayZero() {
        val med = MedicationPlan.Med("a", "药", times = listOf("09:00"), days = listOf(2))
        assertTrue(MedicationPlan.isScheduled(med, today)); assertFalse(MedicationPlan.isScheduled(med, today.plusDays(1)))
    }
    @Test fun archivedMedNeverScheduled() { assertFalse(MedicationPlan.isScheduled(MedicationPlan.Med("a", "药", times = listOf("09:00"), archived = true), today)) }
    @Test fun asNeededMedHasNoSlots() { assertTrue(MedicationPlan.todaySlots(listOf(MedicationPlan.Med("a", "药")), emptyList(), now).isEmpty()) }
    @Test fun dosesMatchSlotsSequentially() {
        val med = MedicationPlan.Med("a", "药", times = listOf("09:00", "21:00"))
        val slots = MedicationPlan.todaySlots(listOf(med), listOf(MedicationPlan.Dose("d", "a", now.minusHours(2))), now)
        assertEquals(MedicationPlan.SlotState.TAKEN, slots[0].state); assertEquals("21:00", MedicationPlan.nextUnrecordedSlot("a", slots)!!.time.toLocalTime().toString())
    }
    @Test fun earlyDoseStrictlyMoreThanOneHour() {
        val slot = MedicationPlan.Slot("a", "药", "", now.plusHours(1), MedicationPlan.SlotState.UPCOMING)
        assertFalse(MedicationPlan.isEarly(slot, now)); assertTrue(MedicationPlan.isEarly(slot.copy(time = now.plusHours(1).plusSeconds(1)), now))
    }
    @Test fun doseImportDeduplicatesSampleId() { assertFalse(MedicationPlan.shouldImport("x", "a", now, listOf(MedicationPlan.Dose("d", "b", now.minusDays(1), healthSampleId = "x")))) }
    @Test fun doseImportDeduplicatesWithin30Minutes() { assertFalse(MedicationPlan.shouldImport("x", "a", now, listOf(MedicationPlan.Dose("d", "a", now.minusMinutes(29))))) }
    @Test fun doseImportDoesNotMergeDifferentMedications() { assertTrue(MedicationPlan.shouldImport("x", "a", now, listOf(MedicationPlan.Dose("d", "b", now)))) }
    @Test fun noPhantomNutritionForUnestimatedRecord() { assertEquals(0.0, com.lodo.app.data.FoodRecordEntity(text = "饭", calories = 500.0).nutrition.calories, 0.0) }
    @Test fun bmiRequiresHeight() { assertNull(WeightPlan.bmi(65.0, null)); assertEquals(25.0, WeightPlan.bmi(100.0, 200.0)!!, 0.0001) }
    @Test fun weightFormatLocaleStable() { assertEquals("60.5", WeightPlan.format(60.5)) }
}
