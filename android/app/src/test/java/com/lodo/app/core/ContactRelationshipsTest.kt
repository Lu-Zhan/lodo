package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

private data class FakeEdge(val uuid: String, val fromUuid: String, val toUuid: String)

class ContactRelationshipsTest {
    private fun resolve(existing: List<FakeEdge>, from: String, to: String, newUuid: String = "new"): String =
        ContactRelationships.resolveUpsertUuid(
            existing, from, to,
            uuidOf = { it.uuid }, fromOf = { it.fromUuid }, toOf = { it.toUuid },
            newUuid = { newUuid },
        )

    @Test
    fun `no existing edge generates a new uuid`() {
        assertEquals("new", resolve(emptyList(), "a", "b"))
    }

    @Test
    fun `existing edge in same order is reused`() {
        val existing = listOf(FakeEdge("edge-1", "a", "b"))
        assertEquals("edge-1", resolve(existing, "a", "b"))
    }

    @Test
    fun `existing edge in reversed order is still reused`() {
        val existing = listOf(FakeEdge("edge-1", "b", "a"))
        assertEquals("edge-1", resolve(existing, "a", "b"))
    }

    @Test
    fun `repeated calls for the same pair keep resolving to the same uuid`() {
        val existing = listOf(FakeEdge("edge-1", "a", "b"))
        assertEquals(resolve(existing, "a", "b", newUuid = "second-call"), resolve(existing, "a", "b", newUuid = "third-call"))
    }

    @Test
    fun `unrelated pair does not match an existing edge`() {
        val existing = listOf(FakeEdge("edge-1", "a", "b"))
        assertNotEquals("edge-1", resolve(existing, "a", "c"))
    }
}
