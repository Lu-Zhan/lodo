package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

class OverviewChartsTest {
    private val today = LocalDate.of(2026, 7, 8)

    private fun report(vararg s: HealthSeries) = HealthReport(s.toList(), 14)

    @Test fun ringsOnlyCountToday() {
        val r = report(
            HealthSeries(HealthMetricKind.STEPS, listOf(HealthDailyPoint(today.minusDays(1), 12000.0), HealthDailyPoint(today, 4000.0))),
            HealthSeries(HealthMetricKind.ACTIVE_ENERGY, listOf(HealthDailyPoint(today, 750.0))),
        )
        val rings = OverviewCharts.rings(r, today)
        assertEquals(1.5, rings.first { it.kind == HealthMetricKind.ACTIVE_ENERGY }.progress!!, 1e-9)
        assertEquals(0.5, rings.first { it.kind == HealthMetricKind.STEPS }.progress!!, 1e-9)
        assertNull(rings.first { it.kind == HealthMetricKind.EXERCISE_MINUTES }.progress)
    }

    @Test fun todayProgressNullWhenNothing() {
        assertNull(OverviewCharts.todayProgress(0, 0).fraction)
        assertEquals(0.25, OverviewCharts.todayProgress(1, 3).fraction!!, 1e-9)
    }

    @Test fun stepTrendLeavesGapsEmpty() {
        val r = report(HealthSeries(HealthMetricKind.STEPS, listOf(HealthDailyPoint(today.minusDays(2), 9000.0))))
        val t = OverviewCharts.stepTrend(r, today)
        assertEquals(7, t.size)
        assertEquals(today, t.last().first)
        assertEquals(9000.0, t[4].second!!, 1e-9)
        assertNull(t[5].second)
    }
}

class NewsSummaryLanguageTest {
    @Test fun storageValuesAndPromptNames() {
        assertEquals(NewsSummaryLanguage.FOLLOW_APP, NewsSummaryLanguage.from(null))
        assertEquals(NewsSummaryLanguage.FOLLOW_APP, NewsSummaryLanguage.from("xx"))
        assertEquals(NewsSummaryLanguage.JAPANESE, NewsSummaryLanguage.from("ja"))
        assertEquals("中文", NewsSummaryLanguage.FOLLOW_APP.promptName("中文"))
        assertEquals("文章原文所用的语言", NewsSummaryLanguage.ORIGINAL.promptName("中文"))
    }
}
