package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 双向同步对账,同 iOS CalendarSyncPlanTests 的用例。 */
class CalendarSyncTest {
    private val h = 3_600_000L
    private val base = 1_783_500_000_000L
    private val window = (base - 7 * 24 * h)..(base + 90 * 24 * h)

    private fun mirror(uuid: String = "A", title: String = "开会", start: Long = base, recurring: Boolean = false) =
        CalendarTaskMirror(uuid, title, start, start + h, false, recurring)
    private fun event(id: String = "1", title: String = "开会", start: Long = base) = SyncEvent(id, title, start, start + h, false)
    private fun record(m: CalendarTaskMirror = mirror(), id: String = "1", own: Boolean = true) = CalendarSyncRecord.from(m, id, own)

    @Test fun newTaskCreatesEvent() {
        val p = CalendarSyncPlanner.plan(emptyList(), listOf(mirror()), emptyList(), window = window)
        assertEquals(listOf(mirror()), p.createEvents)
    }

    @Test fun nothingChangedProducesNoWork() {
        val p = CalendarSyncPlanner.plan(listOf(record()), listOf(mirror()), listOf(event()), window = window)
        assertTrue(p.isEmpty)
        assertEquals(listOf(record()), p.records)
    }

    @Test fun taskEditPushesToEvent() {
        val moved = mirror(start = base + 2 * h)
        val p = CalendarSyncPlanner.plan(listOf(record()), listOf(moved), listOf(event()), window = window)
        assertEquals(listOf("1" to moved), p.updateEvents)
    }

    @Test fun taskGoneDeletesOwnEvent() {
        val p = CalendarSyncPlanner.plan(listOf(record()), emptyList(), listOf(event()), window = window)
        assertEquals(listOf("1"), p.deleteEventIds)
    }

    @Test fun taskGoneDoesNotDeleteForeignEvent() {
        val p = CalendarSyncPlanner.plan(listOf(record(own = false)), emptyList(), listOf(event()), window = window)
        assertTrue(p.deleteEventIds.isEmpty())
        assertTrue(p.records.isEmpty())
    }

    @Test fun eventEditPullsIntoTask() {
        val p = CalendarSyncPlanner.plan(listOf(record()), listOf(mirror()), listOf(event(title = "改名了", start = base + h)), window = window)
        assertEquals(listOf(CalendarTaskUpdate("A", "改名了", base + h, 60, false)), p.updateTasks)
    }

    @Test fun bothChangedTaskWins() {
        val moved = mirror(title = "任务改了")
        val p = CalendarSyncPlanner.plan(listOf(record()), listOf(moved), listOf(event(title = "日历也改了")), window = window)
        assertEquals(listOf("1" to moved), p.updateEvents)
        assertTrue(p.updateTasks.isEmpty())
    }

    @Test fun recurringTaskIgnoresEventEdit() {
        val m = mirror(recurring = true)
        val p = CalendarSyncPlanner.plan(listOf(record(m)), listOf(m), listOf(event(start = base + h)), window = window)
        assertEquals(listOf("1" to m), p.updateEvents)
        assertTrue(p.updateTasks.isEmpty())
    }

    @Test fun eventDeletedInsideWindowDeletesTask() {
        val p = CalendarSyncPlanner.plan(listOf(record()), listOf(mirror()), emptyList(), window = window)
        assertEquals(listOf("A"), p.deleteTaskUuids)
    }

    @Test fun eventOutsideWindowIsNotTreatedAsDeleted() {
        val far = mirror(start = base + 200 * 24 * h)
        val p = CalendarSyncPlanner.plan(listOf(record(far)), listOf(far), emptyList(), window = window)
        assertTrue(p.deleteTaskUuids.isEmpty())
        assertEquals(listOf(record(far)), p.records)
    }

    @Test fun deletingRecurringEventStillDeletesTask() {
        val m = mirror(recurring = true)
        val p = CalendarSyncPlanner.plan(listOf(record(m)), listOf(m), emptyList(), window = window)
        assertEquals(listOf("A"), p.deleteTaskUuids)
    }

    @Test fun claimsEventByUriWhenLedgerIsLost() {
        val p = CalendarSyncPlanner.plan(emptyList(), listOf(mirror()), listOf(event()), mapOf("1" to "A"), window)
        assertTrue(p.createEvents.isEmpty())
        assertTrue(p.updateEvents.isEmpty())
        assertEquals(listOf(record()), p.records)
    }

    @Test fun claimPushesWhenOutOfSync() {
        val p = CalendarSyncPlanner.plan(emptyList(), listOf(mirror()), listOf(event(title = "旧")), mapOf("1" to "A"), window)
        assertEquals(listOf("1" to mirror()), p.updateEvents)
    }

    @Test fun orphanEventIsDeleted() {
        val p = CalendarSyncPlanner.plan(emptyList(), emptyList(), listOf(event()), mapOf("1" to "gone"), window)
        assertEquals(listOf("1"), p.deleteEventIds)
    }

    @Test fun mirrorRulesAndLedgerRoundTrip() {
        assertEquals(null, CalendarTaskMirror.from("A", "x", false, false, base, base, 0, false))
        val m = CalendarTaskMirror.from("A", "x", true, true, base, base + h, 0, false)!!
        assertEquals(base + h, m.start)
        assertEquals(30, m.durationMinutes)
        assertEquals("A", CalendarTaskMirror.taskUuid(m.eventUri))
        assertEquals(null, CalendarTaskMirror.taskUuid("https://example.com"))
        val records = listOf(record(), record(mirror("B"), "2", false))
        assertEquals(records, CalendarSyncRecord.decode(CalendarSyncRecord.encode(records)))
    }
}
