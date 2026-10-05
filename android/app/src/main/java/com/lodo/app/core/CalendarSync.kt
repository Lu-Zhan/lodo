package com.lodo.app.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * 任务 ⇄ 系统日历双向同步的纯逻辑,1:1 移植 iOS `CalendarSyncPlan.swift`。
 * 不碰 CalendarContract、不碰 Room:给它上次的账本、现在的任务、现在的事件,算出两边各要改什么,
 * 执行在 `data/CalendarSync.kt`。时间一律用 epoch 毫秒(全天事项也是本地 0 点的毫秒)。
 */

/** 一条任务在日历上的样子。只镜像**未完成**的事项,重复事项只镜像**下一次**发生。 */
data class CalendarTaskMirror(
    val uuid: String,
    val title: String,
    val start: Long,
    val end: Long,
    val allDay: Boolean,
    /** 重复事项只推不拉:在日历里挪一次发生表达不了整条规则怎么变,下次对账推回原样(删除照常生效)。 */
    val recurring: Boolean = false,
) {
    val durationMinutes: Int get() = maxOf(0, ((end - start) / 60_000).toInt())

    /** 写进事件的链接,同时是回读时认出"这条事件是哪件任务"的凭据。 */
    val eventUri: String get() = "lodo://task/$uuid"

    companion object {
        /** 没填时长的事项在日历上占多久(零长度事件在周/月视图里看不见)。 */
        const val DEFAULT_DURATION_MINUTES = 30

        fun from(
            uuid: String, title: String, pending: Boolean, recurring: Boolean,
            remindAt: Long, nextRemindAt: Long, durationMinutes: Int, allDay: Boolean,
        ): CalendarTaskMirror? {
            if (!pending || title.isBlank()) return null
            val start = if (recurring) nextRemindAt else remindAt
            val minutes = if (durationMinutes > 0) durationMinutes else DEFAULT_DURATION_MINUTES
            return CalendarTaskMirror(uuid, title, start, start + minutes * 60_000L, allDay, recurring)
        }

        /** 反向解析:从事件链接认出任务 uuid,认不出的说明不是 lodo 写的。 */
        fun taskUuid(fromEventUri: String?): String? {
            val uri = fromEventUri ?: return null
            if (!uri.startsWith("lodo://task/")) return null
            return uri.removePrefix("lodo://task/").takeIf { it.isNotBlank() }
        }
    }
}

/** 日历里的一条事件在对账时用到的字段(id 是 CalendarContract 的事件 id)。 */
data class SyncEvent(val id: String, val title: String, val start: Long, val end: Long, val allDay: Boolean)

/** 已建立的镜像关系 + 上次对平时双方的样子(双向同步的全部依据,不靠时间戳)。 */
data class CalendarSyncRecord(
    val taskUuid: String,
    val eventId: String,
    val title: String,
    val start: Long,
    val end: Long,
    val allDay: Boolean,
    /** false = 用户在别的日历里的日程被「转为任务」认领过来的:那条事件归用户,我们只改不删。 */
    val ownCalendar: Boolean,
) {
    fun matches(m: CalendarTaskMirror) = title == m.title && start == m.start && end == m.end && allDay == m.allDay
    fun matches(e: SyncEvent) = title == e.title && start == e.start && end == e.end && allDay == e.allDay

    fun toJson(): JSONObject = JSONObject().put("task", taskUuid).put("event", eventId).put("title", title)
        .put("start", start).put("end", end).put("allDay", allDay).put("own", ownCalendar)

    companion object {
        fun from(m: CalendarTaskMirror, eventId: String, own: Boolean) =
            CalendarSyncRecord(m.uuid, eventId, m.title, m.start, m.end, m.allDay, own)

        fun from(e: SyncEvent, taskUuid: String, own: Boolean) =
            CalendarSyncRecord(taskUuid, e.id, e.title, e.start, e.end, e.allDay, own)

        fun fromJson(o: JSONObject) = CalendarSyncRecord(
            o.optString("task"), o.optString("event"), o.optString("title"), o.optLong("start"),
            o.optLong("end"), o.optBoolean("allDay"), o.optBoolean("own", true),
        )

        fun encode(records: List<CalendarSyncRecord>): String =
            JSONArray().also { a -> records.forEach { a.put(it.toJson()) } }.toString()

        fun decode(json: String): List<CalendarSyncRecord> = runCatching {
            val a = JSONArray(json)
            (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(::fromJson) }
                .filter { it.taskUuid.isNotBlank() && it.eventId.isNotBlank() }
        }.getOrDefault(emptyList())
    }
}

/** 事件那边改了之后要回写进任务的值。 */
data class CalendarTaskUpdate(val uuid: String, val title: String, val start: Long, val durationMinutes: Int, val allDay: Boolean)

/** 一次对账要做的事。 */
data class CalendarSyncPlan(
    val createEvents: List<CalendarTaskMirror> = emptyList(),
    val updateEvents: List<Pair<String, CalendarTaskMirror>> = emptyList(),
    val deleteEventIds: List<String> = emptyList(),
    val updateTasks: List<CalendarTaskUpdate> = emptyList(),
    val deleteTaskUuids: List<String> = emptyList(),
    val records: List<CalendarSyncRecord> = emptyList(),
) {
    val isEmpty: Boolean
        get() = createEvents.isEmpty() && updateEvents.isEmpty() && deleteEventIds.isEmpty() &&
            updateTasks.isEmpty() && deleteTaskUuids.isEmpty()
}

object CalendarSyncPlanner {
    /**
     * @param tasks 现在**未完成**的任务镜像(完成的不在里面,等同于"任务没了")。
     * @param events 窗口内和我们有关的事件:自家日历的全部 + 账本里认领过的别人家日历那几条。
     * @param claimed 自家日历里事件链接上写着的任务 uuid(eventId → uuid),账本丢了时靠它认回来。
     * @param window 这次查询覆盖的时间范围。**窗口外查不到 ≠ 被删**。
     */
    fun plan(
        records: List<CalendarSyncRecord>,
        tasks: List<CalendarTaskMirror>,
        events: List<SyncEvent>,
        claimed: Map<String, String> = emptyMap(),
        window: LongRange,
    ): CalendarSyncPlan {
        val create = mutableListOf<CalendarTaskMirror>()
        val updateEvents = mutableListOf<Pair<String, CalendarTaskMirror>>()
        val deleteEvents = mutableListOf<String>()
        val updateTasks = mutableListOf<CalendarTaskUpdate>()
        val deleteTasks = mutableListOf<String>()
        val out = mutableListOf<CalendarSyncRecord>()
        val tasksByUuid = tasks.associateBy { it.uuid }
        val eventsById = LinkedHashMap<String, SyncEvent>().also { m -> events.forEach { m.putIfAbsent(it.id, it) } }
        val handledTasks = mutableSetOf<String>()
        val handledEvents = mutableSetOf<String>()

        for (record in records) {
            handledTasks += record.taskUuid
            handledEvents += record.eventId
            val task = tasksByUuid[record.taskUuid]
            val event = eventsById[record.eventId]
            when {
                task != null && event != null -> {
                    val taskChanged = !record.matches(task)
                    val eventChanged = !record.matches(event)
                    if (taskChanged || (eventChanged && task.recurring)) {
                        // 两边都改了也走这支:任务这边赢(lodo 才是任务的所有者)。
                        updateEvents += record.eventId to task
                        out += CalendarSyncRecord.from(task, record.eventId, record.ownCalendar)
                    } else if (eventChanged) {
                        updateTasks += CalendarTaskUpdate(
                            record.taskUuid, event.title, event.start,
                            maxOf(0, ((event.end - event.start) / 60_000).toInt()), event.allDay,
                        )
                        out += CalendarSyncRecord.from(event, record.taskUuid, record.ownCalendar)
                    } else {
                        out += record
                    }
                }
                task != null -> {
                    // 事件不见了:只有本该在这次查询范围内时才算被删。
                    if (record.start in window) deleteTasks += record.taskUuid else out += record
                }
                event != null -> {
                    // 任务没了:自家日历的事件跟着删,别人家的只解除关系。
                    if (record.ownCalendar) deleteEvents += event.id
                }
                else -> Unit
            }
        }
        for (task in tasks) if (task.uuid !in handledTasks) create += task

        for ((eventId, uuid) in claimed) {
            if (eventId in handledEvents) continue
            val event = eventsById[eventId] ?: continue
            val task = tasksByUuid[uuid]
            if (task != null) {
                create.removeAll { it.uuid == uuid }
                if (!CalendarSyncRecord.from(task, eventId, true).matches(event)) updateEvents += eventId to task
                out += CalendarSyncRecord.from(task, eventId, true)
            } else {
                deleteEvents += eventId
            }
        }
        return CalendarSyncPlan(create, updateEvents, deleteEvents, updateTasks, deleteTasks, out)
    }
}
