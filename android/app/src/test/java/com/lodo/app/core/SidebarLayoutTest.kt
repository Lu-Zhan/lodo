package com.lodo.app.core

import org.junit.Assert.*
import org.junit.Test

class SidebarLayoutTest {
    private val ids = listOf("OVERVIEW", "TASKS", "CALENDAR", "COUNTDOWN", "MEMORY", "CONTACTS",
        "ASSETS", "HEALTH", "TRAVEL", "MENU", "NEWS", "AGENT")

    @Test fun defaultsShowEveryItemInDefaultOrder() {
        val layout = SidebarLayout.defaults(ids)
        assertEquals(ids, layout.items.map { it.id })
        assertTrue(layout.items.all { it.visible })
        assertEquals(layout, SidebarLayout.decode(null, ids))
        assertEquals(layout, SidebarLayout.decode("", ids))
    }

    @Test fun roundTripPreservesOrderAndVisibility() {
        val layout = SidebarLayout.defaults(ids).move("AGENT", "OVERVIEW").setVisible("TASKS", false)
        assertEquals(layout, SidebarLayout.decode(layout.encode(), ids))
        assertTrue(layout.encode().contains("AGENT"))
    }

    @Test fun unknownIdsAreSkipped() {
        val layout = SidebarLayout.decode("""[{"id":"REMOVED","visible":false},{"id":"TASKS"}]""", ids)
        assertEquals(listOf("TASKS") + ids.filter { it != "TASKS" }, layout.items.map { it.id })
        assertTrue(layout.items.all { it.visible })
    }

    @Test fun duplicatesKeepFirstVisibilityAndPosition() {
        val layout = SidebarLayout.decode("""[{"id":"TASKS","visible":false},{"id":"OVERVIEW"},{"id":"TASKS","visible":true}]""", ids)
        assertEquals(listOf("TASKS", "OVERVIEW") + ids.drop(2), layout.items.map { it.id })
        assertFalse(layout.items.first().visible)
    }

    @Test fun newItemsAreAppendedInDefaultOrder() {
        val old = SidebarLayout.defaults(listOf("TASKS", "OVERVIEW")).setVisible("OVERVIEW", false)
        val upgraded = SidebarLayout.decode(old.encode(), ids)
        assertEquals(old.items + ids.drop(2).map { SidebarLayout.Item(it) }, upgraded.items)
    }

    @Test fun moveReordersBothDirectionsAndKeepsVisibility() {
        val layout = SidebarLayout.defaults(ids).setVisible("TASKS", false)
        val moved = layout.move("TASKS", "COUNTDOWN")
        assertEquals(listOf("OVERVIEW", "CALENDAR", "COUNTDOWN", "TASKS") + ids.drop(4), moved.items.map { it.id })
        assertFalse(moved.items[3].visible)
        assertEquals(layout, moved.move("TASKS", "CALENDAR"))
        assertEquals(layout, layout.move("UNKNOWN", "TASKS"))
        assertEquals(layout, layout.move("TASKS", "UNKNOWN"))
        assertEquals(layout, layout.move("TASKS", "TASKS"))
    }

    @Test fun hideAndShowPreserveOrder() {
        val layout = SidebarLayout.defaults(ids)
        val hidden = layout.setVisible("TASKS", false)
        assertEquals(ids, hidden.items.map { it.id })
        assertFalse(hidden.items[1].visible)
        assertEquals(layout, hidden.setVisible("TASKS", true))
        assertEquals(layout, layout.setVisible("UNKNOWN", false))
    }

    @Test fun allItemsCanBeHiddenAndRestored() {
        val hidden = ids.fold(SidebarLayout.defaults(ids)) { layout, id -> layout.setVisible(id, false) }
        assertTrue(hidden.items.none { it.visible })
        assertEquals(hidden, SidebarLayout.decode(hidden.encode(), ids))
        assertEquals(listOf("AGENT"), hidden.setVisible("AGENT", true).items.filter { it.visible }.map { it.id })
    }

    @Test fun malformedJsonFallsBackToDefaults() {
        listOf("not json", "{}", "null", "[{", "[]").forEach {
            assertEquals(SidebarLayout.defaults(ids), SidebarLayout.decode(it, ids))
        }
    }

    @Test fun malformedEntriesAreSkippedAndInvalidVisibilityDefaultsToShown() {
        val layout = SidebarLayout.decode("""[null,42,"TASKS",{}, {"id":2}, {"id":"TASKS","visible":"false"}, {"id":"AGENT","visible":false}]""", ids)
        assertEquals(listOf("TASKS", "AGENT") + ids.filter { it != "TASKS" && it != "AGENT" }, layout.items.map { it.id })
        assertTrue(layout.items[0].visible)
        assertFalse(layout.items[1].visible)
    }
}
