package com.lodo.app.notify

import org.junit.Assert.assertEquals
import org.junit.Test

class NotifyBackoffTest {
    @Test
    fun risesLinearlyBeforeCap() {
        assertEquals(5L, NotifyBackoff.minutes(1))
        assertEquals(15L, NotifyBackoff.minutes(3))
    }

    @Test
    fun capsAtThirtyMinutes() {
        assertEquals(30L, NotifyBackoff.minutes(6))
        assertEquals(30L, NotifyBackoff.minutes(10))
    }
}
