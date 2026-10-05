package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Test

class CalendarLayoutTest {
    @Test fun separateEventsGetFullWidth() {
        val r = CalendarLayout.columns(listOf(540 to 600, 660 to 720))
        assertEquals(listOf(0, 0), r.map { it.column })
        assertEquals(listOf(1, 1), r.map { it.columns })
    }

    @Test fun overlappingEventsSplitColumns() {
        val r = CalendarLayout.columns(listOf(540 to 660, 600 to 690, 700 to 760))
        assertEquals(listOf(0, 1, 0), r.map { it.column })
        assertEquals(listOf(2, 2, 1), r.map { it.columns })
    }

    @Test fun freedColumnIsReused() {
        // 同时开始时长的先占左列;短的那条结束后,第三条接着用它空出来的列。
        val r = CalendarLayout.columns(listOf(540 to 600, 540 to 720, 610 to 650))
        assertEquals(listOf(1, 0, 1), r.map { it.column })
        assertEquals(listOf(2, 2, 2), r.map { it.columns })
    }
}
