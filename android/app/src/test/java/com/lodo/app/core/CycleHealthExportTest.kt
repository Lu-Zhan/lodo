package com.lodo.app.core

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class CycleHealthExportTest {
    private val today = LocalDate.of(2026, 7, 8)
    private fun day(offset: Long) = today.plusDays(offset)
    private fun desired(periods: List<CyclePeriod>, flows: List<CycleFlow.ManualEntry> = emptyList(), foreign: Set<String> = emptySet(), limit: Int = 5) =
        CycleHealthExport.desired(periods, flows, foreign, day(-29), today, limit)
    private fun flow(offset: Long, raw: String, deleted: Boolean = false, updated: Long = 1) =
        CycleFlow.ManualEntry("f$updated", day(offset).toString(), raw, updated, deleted)

    @Test fun closedPeriodExportsEachDayAndFlow() {
        val result = desired(listOf(CyclePeriod("p", day(-2), today)), listOf(flow(-1, "heavy")))
        assertEquals(3, result.size)
        assertEquals(CycleFlowLevel.HEAVY, result[day(-1).toString()]?.level)
        assertEquals(CycleFlowLevel.UNSPECIFIED, result[today.toString()]?.level)
    }
    @Test fun openPeriodIsCappedAndNeverExportsFuture() {
        assertEquals(5, desired(listOf(CyclePeriod("p", day(-10)))).size)
        assertEquals(2, desired(listOf(CyclePeriod("p", day(-1))), limit = 5).size)
        assertTrue(desired(listOf(CyclePeriod("p", day(1)))).isEmpty())
    }
    @Test fun foreignDaysAndWindowAreUntouched() {
        val result = desired(listOf(CyclePeriod("p", day(-35), today)), foreign = setOf(today.toString()))
        assertEquals(29, result.size)
        assertFalse(result.containsKey(day(-30).toString()))
        assertFalse(result.containsKey(today.toString()))
    }
    @Test fun flowsOutsidePeriodsAndImportedPeriodsAreNotExported() {
        assertTrue(desired(emptyList(), listOf(flow(0, "heavy"))).isEmpty())
        assertTrue(desired(listOf(CyclePeriod("h", day(-2), today, true))).isEmpty())
    }
    @Test fun tombstoneUnknownAndNone() {
        val periods = listOf(CyclePeriod("p", day(-2), today))
        val result = desired(periods, listOf(flow(-2, "light"), flow(-2, "heavy", true, 2), flow(-1, "unknown"), flow(0, "none")))
        assertEquals(CycleFlowLevel.UNSPECIFIED, result[day(-2).toString()]?.level)
        assertEquals(CycleFlowLevel.UNSPECIFIED, result[day(-1).toString()]?.level)
        assertFalse(result.containsKey(today.toString()))
    }
    @Test fun planKeepsOneMatchingSampleDeletesStaleAndAddsMissing() {
        val a = CycleHealthExport.Day(day(-1).toString(), CycleFlowLevel.LIGHT)
        val b = CycleHealthExport.Day(today.toString(), CycleFlowLevel.HEAVY)
        val stale = CycleHealthExport.Day(day(-2).toString(), CycleFlowLevel.MEDIUM)
        val result = CycleHealthExport.plan(mapOf(a.dayKey to a, b.dayKey to b), listOf(
            CycleHealthExport.Existing("2", a), CycleHealthExport.Existing("1", a), CycleHealthExport.Existing("3", stale)))
        assertEquals(listOf("2", "3"), result.delete)
        assertEquals(listOf(b), result.add)
        val unchanged = CycleHealthExport.plan(mapOf(a.dayKey to a), listOf(CycleHealthExport.Existing("1", a)))
        assertTrue(unchanged.delete.isEmpty() && unchanged.add.isEmpty())
    }
    @Test fun changedLevelReplacesOwnedSample() {
        val want = CycleHealthExport.Day(today.toString(), CycleFlowLevel.HEAVY)
        val result = CycleHealthExport.plan(mapOf(want.dayKey to want), listOf(CycleHealthExport.Existing("id", want.copy(level = CycleFlowLevel.LIGHT))))
        assertEquals(listOf("id"), result.delete)
        assertEquals(listOf(want), result.add)
    }
}
