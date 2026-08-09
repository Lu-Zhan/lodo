package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.hypot

class ContactGraphLayoutTest {
    @Test
    fun `empty for zero or negative count`() {
        assertEquals(emptyList<Pair<Double, Double>>(), ContactGraphLayout.circlePositions(0, 100.0))
        assertEquals(emptyList<Pair<Double, Double>>(), ContactGraphLayout.circlePositions(-1, 100.0))
    }

    @Test
    fun `single node sits at center`() {
        assertEquals(listOf(0.0 to 0.0), ContactGraphLayout.circlePositions(1, 100.0))
    }

    @Test
    fun `first node starts at top`() {
        val positions = ContactGraphLayout.circlePositions(4, 100.0)
        val (x, y) = positions[0]
        assertTrue(abs(x) < 1e-9)
        assertTrue(abs(y - (-100.0)) < 1e-9)
    }

    @Test
    fun `all nodes sit on the circle`() {
        val radius = 50.0
        ContactGraphLayout.circlePositions(6, radius).forEach { (x, y) ->
            assertEquals(radius, hypot(x, y), 1e-9)
        }
    }

    @Test
    fun `nodes are evenly spaced`() {
        val positions = ContactGraphLayout.circlePositions(3, 10.0)
        assertEquals(3, positions.distinct().size)
    }
}
