package com.lodo.app.core

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

class RoutineTimelineTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)
    @Test fun disabledNotShownEvenWhenRanToday() { assertNull(RoutineTimeline.displayTime(false, now.minusHours(1), now.plusDays(1), now)) }
    @Test fun todayRunKeepsTodaysRowEvenWhenNextIsTomorrow() { assertEquals(now.minusHours(1), RoutineTimeline.displayTime(true, now.minusHours(1), now.plusDays(1), now)) }
    @Test fun olderRunDoesNotReplaceUpcoming() { assertEquals(now.plusHours(1), RoutineTimeline.displayTime(true, now.minusDays(1), now.plusHours(1), now)) }
    @Test fun neverRunUsesNextTime() { assertEquals(now.plusHours(1), RoutineTimeline.displayTime(true, null, now.plusHours(1), now)) }
    @Test fun noRunOrScheduleMeansNoRow() { assertNull(RoutineTimeline.displayTime(true, null, null, now)) }
    @Test fun todayResultCanRemainWithoutNextTime() { assertEquals(now.minusHours(1), RoutineTimeline.displayTime(true, now.minusHours(1), null, now)) }
    @Test fun priorDayWithoutNextTimeNotShown() { assertNull(RoutineTimeline.displayTime(true, now.minusDays(1), null, now)) }
}
