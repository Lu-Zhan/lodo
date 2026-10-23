package com.lodo.app.ai

import com.lodo.app.core.RepeatType
import com.lodo.app.core.TaskInbox
import com.lodo.app.data.TaskEntity
import com.lodo.app.data.toEpochMillis
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDateTime
import java.util.TimeZone

/** 对齐 iOS 收集协议,不发网络请求、不依赖 Android 服务。 */
class TaskInboxTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)
    private fun task(inbox: Boolean) = ParsedTask("买牙膏", if (inbox) TaskInbox.date else now,
        false, 0, RepeatType.NONE, emptyList(), emptyList())

    private fun parse(action: JSONObject, ids: Set<String> = emptySet()): AIAction =
        (DeepSeekClient.parseCommandResult(JSONObject().put("actions", JSONArray().put(action)), ids, false)
            as AICommandResult.Actions).actions.single()

    @Test fun sentinelMatchesIOSDistantFuture() {
        assertEquals(Instant.parse("4001-01-01T00:00:00Z").toEpochMilli(), TaskInbox.EPOCH_MILLIS)
        assertEquals(TaskInbox.EPOCH_MILLIS, TaskInbox.date.toEpochMillis())
    }

    @Test fun sentinelSurvivesTimeZoneChanges() {
        val previous = TimeZone.getDefault()
        try {
            for (zone in listOf("Pacific/Honolulu", "Asia/Shanghai", "Pacific/Kiritimati")) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone))
                val entity = TaskEntity.create("买牙膏", TaskInbox.date)
                assertTrue(entity.isInbox)
                assertTrue(entity.toParsedTask().isInbox)
                assertEquals(TaskInbox.EPOCH_MILLIS, entity.remindAtMillis)
            }
        } finally { TimeZone.setDefault(previous) }
    }

    @Test fun ordinaryTaskIsNotInbox() { assertFalse(task(false).isInbox) }

    @Test fun createInboxNormalizesScheduleFields() {
        val result = parse(JSONObject().put("action", "create").put("title", "买牙膏")
            .put("inbox", true).put("remind_at", "").put("all_day", true)
            .put("duration_minutes", 60).put("repeat_type", "daily")
            .put("repeat_times", JSONArray(listOf("09:00"))).put("project", "生活")) as AIAction.Create
        assertTrue(result.task.isInbox)
        assertFalse(result.task.allDay)
        assertEquals(0, result.task.durationMinutes)
        assertEquals(RepeatType.NONE, result.task.repeatType)
        assertTrue(result.task.repeatTimes.isEmpty())
        assertEquals("生活", result.task.project)
    }

    @Test fun updateScheduledTaskToInboxKeepsIdentity() {
        val id = "12345678-0000-0000-0000-000000000000"
        val result = parse(JSONObject().put("action", "update").put("uuid", id)
            .put("title", "买牙膏").put("inbox", true), setOf(id)) as AIAction.Update
        assertEquals(id, result.uuid)
        assertTrue(result.task.isInbox)
    }

    @Test fun updateInboxToScheduledTaskKeepsIdentity() {
        val id = "12345678-0000-0000-0000-000000000000"
        val result = parse(JSONObject().put("action", "update").put("uuid", id)
            .put("title", "买牙膏").put("inbox", false).put("remind_at", "2026-07-08 22:00"), setOf(id)) as AIAction.Update
        assertEquals(id, result.uuid)
        assertFalse(result.task.isInbox)
        assertEquals(now.withHour(22), result.task.remindAt)
    }

    @Test(expected = DeepSeekException::class)
    fun missingTimeWithoutExplicitInboxStillFails() {
        parse(JSONObject().put("action", "create").put("title", "买牙膏"))
    }

    @Test(expected = DeepSeekException::class)
    fun stringTrueIsNotExplicitInbox() {
        parse(JSONObject().put("action", "create").put("title", "买牙膏").put("inbox", "true"))
    }

    @Test(expected = DeepSeekException::class)
    fun inboxRequiresTitle() {
        parse(JSONObject().put("action", "create").put("title", " ").put("inbox", true))
    }

    @Test fun promptReservesTwentyInboxSlots() {
        val tasks = (1..70).map { "scheduled-$it" to task(false) } + (1..30).map { "inbox-$it" to task(true) }
        val selected = DeepSeekClient.commandTasks(tasks)
        assertEquals(50, selected.size)
        assertEquals(20, selected.count { it.second.isInbox })
        assertEquals(30, selected.count { !it.second.isInbox })
    }

    @Test fun promptFillsUnusedScheduledSlotsWithInbox() {
        val tasks = (1..5).map { "scheduled-$it" to task(false) } + (1..60).map { "inbox-$it" to task(true) }
        assertEquals(45, DeepSeekClient.commandTasks(tasks).count { it.second.isInbox })
    }

    @Test fun promptIncludesInboxFlagAndNoSentinelDate() {
        val prompt = DeepSeekClient.commandSystemPrompt(AIConfig(null, "", ""), CommandContext(listOf("inbox" to task(true))))
        val list = JSONArray(prompt.substringAfter("当前待办列表:\n").substringBefore("\n\n"))
        assertTrue(list.getJSONObject(0).getBoolean("inbox"))
        assertEquals("", list.getJSONObject(0).getString("remind_at"))
    }

    @Test fun entityRoundTripAndCaptionDoNotExposeYear4001() {
        val entity = TaskEntity.create("买牙膏", TaskInbox.date)
        assertTrue(entity.withData(entity.toData()).isInbox)
        assertEquals("收集", entity.caption())
    }
}
