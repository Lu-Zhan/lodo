package com.lodo.app.ui.todo

import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TaskInbox
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

class TaskFormTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)
    private fun source(inbox: Boolean) = ParsedTask("买牙膏", if (inbox) TaskInbox.date else now,
        false, 0, RepeatType.NONE, emptyList(), emptyList(), "生活")

    @Test fun blankManualFormDefaultsToInbox() {
        val form = TaskFormState(null)
        assertTrue(form.inbox)
        assertFalse(form.isValid)
        form.title = " 买牙膏 "
        val parsed = form.makeParsed("09:00")!!
        assertTrue(parsed.isInbox)
        assertEquals("买牙膏", parsed.title)
    }

    @Test fun inboxIgnoresHiddenRepeatAndDurationFields() {
        val form = TaskFormState(source(false))
        form.inbox = true
        form.duration = 60
        form.repeatType = RepeatType.WEEKLY
        val result = form.makeParsed("09:00")!!
        assertTrue(result.isInbox)
        assertEquals(RepeatType.NONE, result.repeatType)
        assertEquals(0, result.durationMinutes)
        assertEquals("生活", result.project)
    }

    @Test fun leavingInboxUsesRealDateNotYear4001() {
        val form = TaskFormState(source(true))
        form.inbox = false
        val result = form.makeParsed("09:00")!!
        assertFalse(result.isInbox)
        assertTrue(result.remindAt.year < 4001)
        assertEquals("生活", result.project)
    }

    @Test fun aiCanMoveTaskInAndOutOfInbox() {
        val form = TaskFormState(source(false))
        form.apply(source(true))
        assertTrue(form.makeParsed("09:00")!!.isInbox)
        form.apply(source(false))
        val result = form.makeParsed("09:00")!!
        assertFalse(result.isInbox)
        assertEquals(now, result.remindAt)
        assertEquals("生活", result.project)
    }
}
