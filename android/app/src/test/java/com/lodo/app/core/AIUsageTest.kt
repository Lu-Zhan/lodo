package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AIUsageTest {
    @Test fun formatCount() {
        assertEquals("999", AIUsage.formatCount(999))
        assertEquals("1.2k", AIUsage.formatCount(1234))
        assertEquals("2k", AIUsage.formatCount(2000))
        assertEquals("13k", AIUsage.formatCount(12_600))
    }

    @Test fun exactUsageAcrossTwoRequestsExcludesToolWait() {
        val a = AIUsageAccumulator()
        a.beginRequest(0); a.markDelta(500); a.report(1000, 50, 1500); a.endRequest(1500)
        // 中间联网搜索等了 5 秒,不算进生成时长
        a.beginRequest(6500); a.markDelta(7000); a.report(1200, 150, 8000); a.endRequest(8000)
        val u = a.snapshot(9000)
        assertEquals(2200, u.inputTokens)
        assertEquals(200, u.outputTokens)
        assertFalse(u.isEstimated)
        assertEquals(2.0, u.generatingSeconds, 1e-9)
        assertEquals("↑2.2k ↓200 · 100 tok/s", u.badge)
    }

    @Test fun missingUsageFallsBackToDeltaCount() {
        val a = AIUsageAccumulator()
        a.beginRequest(0)
        repeat(30) { a.markDelta(1000L + it * 50) }
        a.endRequest(2500)
        val u = a.snapshot(2600)
        assertTrue(u.isEstimated)
        assertEquals("↓≈30 · 20 tok/s", u.badge)
    }

    @Test fun streamingShowsOnlySpeed() {
        val a = AIUsageAccumulator()
        a.beginRequest(0)
        assertTrue(a.markDelta(100))
        assertFalse(a.markDelta(200))
        repeat(9) { a.markDelta(300L + it * 10) }
        val u = a.snapshot(1100)
        assertTrue(u.isStreaming)
        assertEquals("11 tok/s", u.badge)
        assertNull(AIUsage().badge)
    }
}
