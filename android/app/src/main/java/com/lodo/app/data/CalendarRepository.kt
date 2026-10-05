package com.lodo.app.data

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/** 系统日历里的一次日程(重复日程的每一次各是一条,occurrenceKey 区分),对应 iOS CalendarEvent。 */
data class CalendarEvent(
    val eventId: Long,
    val title: String,
    val start: LocalDateTime,
    val end: LocalDateTime,
    val allDay: Boolean,
    val calendarName: String,
    val color: Int,
    val location: String,
    /** 这一次发生的原始开始时刻(毫秒),删除"仅这一次"时要用它建例外。 */
    val beginMillis: Long = 0,
    val endMillis: Long = 0,
    val description: String = "",
    /** 重复规则,非空 = 重复日程(删除时问"这一次/所有")。 */
    val rrule: String = "",
    val calendarId: Long = 0,
) {
    val occurrenceKey get() = "$eventId-${start}"

    /** 归在哪些天(跨天日程每天都出现;全天的结束日是"下一天 0 点",不算)。 */
    fun covers(day: LocalDate): Boolean {
        val s = start.toLocalDate()
        val e = if (allDay) end.toLocalDate().minusDays(1) else (if (end.toLocalTime() == java.time.LocalTime.MIDNIGHT && end.isAfter(start)) end.toLocalDate().minusDays(1) else end.toLocalDate())
        return !day.isBefore(s) && !day.isAfter(maxOf(s, e))
    }
}

/**
 * 系统日历(CalendarContract)只读桥接,对应 iOS CalendarBridge 的读那一半:读 Instances 表
 * (重复日程按每一次展开)。开关 calendarEnabled 默认关、没授权时一次都不查。
 * 编辑/删除交给系统日历 app(ACTION_VIEW 打开那一次),lodo 不直接写用户的日程。
 */
class CalendarRepository(private val context: Context) {
    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    suspend fun events(from: LocalDate, to: LocalDate): List<CalendarEvent> = withContext(Dispatchers.IO) {
        if (!hasPermission()) return@withContext emptyList()
        val zone = ZoneId.systemDefault()
        val begin = from.atStartOfDay(zone).toInstant().toEpochMilli()
        val end = to.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, begin)
            ContentUris.appendId(it, end)
        }.build()
        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
            CalendarContract.Instances.DISPLAY_COLOR, CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.DESCRIPTION, CalendarContract.Instances.RRULE,
            CalendarContract.Instances.CALENDAR_ID,
        )
        // lodo 自己那本(镜像任务的)不在日历页显示:任务在任务页看,不然会出现两遍(同 iOS)。
        val own = ownCalendarId()
        val result = mutableListOf<CalendarEvent>()
        runCatching {
            context.contentResolver.query(uri, projection, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
                while (c.moveToNext()) {
                    val allDay = c.getInt(4) == 1
                    // 全天日程在库里按 UTC 存,按 UTC 解出日期再落到本地 0 点。
                    fun time(ms: Long) = if (allDay) LocalDateTime.ofInstant(Instant.ofEpochMilli(ms), ZoneOffset.UTC)
                    else LocalDateTime.ofInstant(Instant.ofEpochMilli(ms), zone)
                    CalendarEvent(
                        eventId = c.getLong(0), title = c.getString(1) ?: "", start = time(c.getLong(2)),
                        end = time(c.getLong(3)), allDay = allDay, calendarName = c.getString(5) ?: "",
                        color = c.getInt(6), location = c.getString(7) ?: "",
                        beginMillis = c.getLong(2), endMillis = c.getLong(3),
                        description = c.getString(8) ?: "", rrule = c.getString(9) ?: "",
                        calendarId = c.getLong(10),
                    ).takeIf { it.calendarId != own }?.let { result += it }
                }
            }
        }
        result
    }

    /** 打开系统日历里的这一次(编辑/删除都由用户在系统界面里确认)。 */
    fun openIntent(event: CalendarEvent): Intent {
        val zone = ZoneId.systemDefault()
        return Intent(Intent.ACTION_VIEW, ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, event.eventId))
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, event.start.atZone(zone).toInstant().toEpochMilli())
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, event.end.atZone(zone).toInstant().toEpochMilli())
    }

    // ---------------------------------------------------------------------------------------------
    // 写(双向同步与日历页的删除),对应 iOS CalendarBridge 的写那一半。

    fun hasWritePermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    /** 删除用户的一条日程。`onlyThis` 且是重复日程时只删这一次(插一条取消状态的例外)。 */
    suspend fun delete(event: CalendarEvent, onlyThis: Boolean): Boolean = withContext(Dispatchers.IO) {
        if (!hasWritePermission()) return@withContext false
        runCatching {
            if (onlyThis && event.rrule.isNotBlank()) {
                val values = android.content.ContentValues().apply {
                    put(CalendarContract.Events.ORIGINAL_INSTANCE_TIME, event.beginMillis)
                    put(CalendarContract.Events.STATUS, CalendarContract.Events.STATUS_CANCELED)
                }
                val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_EXCEPTION_URI, event.eventId)
                context.contentResolver.insert(uri, values) != null
            } else {
                context.contentResolver.delete(
                    ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, event.eventId), null, null) > 0
            }
        }.getOrDefault(false)
    }

    private fun asSyncAdapter(uri: android.net.Uri): android.net.Uri = uri.buildUpon()
        .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, OWN_ACCOUNT)
        .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
        .build()

    /** lodo 自己那本日历的 id(本地账户,不随任何云账户同步);没有返回 null。 */
    fun ownCalendarId(): Long? {
        if (!hasPermission()) return null
        return runCatching {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI, arrayOf(CalendarContract.Calendars._ID),
                "${CalendarContract.Calendars.ACCOUNT_NAME}=? AND ${CalendarContract.Calendars.ACCOUNT_TYPE}=?",
                arrayOf(OWN_ACCOUNT, CalendarContract.ACCOUNT_TYPE_LOCAL), null,
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        }.getOrNull()
    }

    private fun ensureOwnCalendar(): Long? {
        ownCalendarId()?.let { return it }
        if (!hasWritePermission()) return null
        val values = android.content.ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, OWN_ACCOUNT)
            put(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(CalendarContract.Calendars.NAME, OWN_CALENDAR_TITLE)
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, OWN_CALENDAR_TITLE)
            put(CalendarContract.Calendars.CALENDAR_COLOR, 0xFFC2410C.toInt())
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, OWN_ACCOUNT)
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
            put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, ZoneId.systemDefault().id)
        }
        return runCatching {
            context.contentResolver.insert(asSyncAdapter(CalendarContract.Calendars.CONTENT_URI), values)?.let { ContentUris.parseId(it) }
        }.getOrNull()
    }

    /** 自家日历在窗口内的事件 + 事件链接上写着的任务 uuid(账本丢了时靠它认回来)。 */
    suspend fun ownEvents(window: LongRange): Pair<List<com.lodo.app.core.SyncEvent>, Map<String, String>> = withContext(Dispatchers.IO) {
        val id = ownCalendarId() ?: return@withContext emptyList<com.lodo.app.core.SyncEvent>() to emptyMap()
        val events = mutableListOf<com.lodo.app.core.SyncEvent>()
        val claimed = mutableMapOf<String, String>()
        runCatching {
            context.contentResolver.query(
                CalendarContract.Events.CONTENT_URI, EVENT_PROJECTION,
                "${CalendarContract.Events.CALENDAR_ID}=? AND ${CalendarContract.Events.DTSTART}>=? AND ${CalendarContract.Events.DTSTART}<=? AND ${CalendarContract.Events.DELETED}=0",
                arrayOf(id.toString(), window.first.toString(), window.last.toString()), null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val e = syncEvent(c)
                    events += e
                    com.lodo.app.core.CalendarTaskMirror.taskUuid(c.getString(5))?.let { claimed[e.id] = it }
                }
            }
        }
        events to claimed
    }

    /** 按 id 取几条事件(账本里认领过的别人家日历那几条);取不到 = 被删了。 */
    suspend fun eventsWithIds(ids: List<String>): List<com.lodo.app.core.SyncEvent> = withContext(Dispatchers.IO) {
        if (ids.isEmpty() || !hasPermission()) return@withContext emptyList()
        val out = mutableListOf<com.lodo.app.core.SyncEvent>()
        runCatching {
            context.contentResolver.query(
                CalendarContract.Events.CONTENT_URI, EVENT_PROJECTION,
                "${CalendarContract.Events._ID} IN (${ids.joinToString(",") { "?" }}) AND ${CalendarContract.Events.DELETED}=0",
                ids.toTypedArray(), null,
            )?.use { c -> while (c.moveToNext()) out += syncEvent(c) }
        }
        out
    }

    private fun syncEvent(c: android.database.Cursor): com.lodo.app.core.SyncEvent {
        val allDay = c.getInt(4) == 1
        val start = c.getLong(2)
        val end = if (c.isNull(3)) start else c.getLong(3)
        return com.lodo.app.core.SyncEvent(
            c.getLong(0).toString(), c.getString(1) ?: "",
            if (allDay) utcDayToLocal(start) else start, if (allDay) utcDayToLocal(end) else end, allDay,
        )
    }

    /**
     * 执行 plan 的事件那一侧,返回新建出来的事件 id(任务 uuid → 事件 id)。
     * 自家日历走同步适配器身份(本地账户的删除才是真删,不留 DELETED 标记);
     * **链接只写在自家日历的事件上**——别人家的日程归用户,不往上盖 lodo:// 链接。
     */
    suspend fun apply(plan: com.lodo.app.core.CalendarSyncPlan): Map<String, String> = withContext(Dispatchers.IO) {
        val calendarId = ensureOwnCalendar() ?: return@withContext emptyMap()
        val created = mutableMapOf<String, String>()
        val resolver = context.contentResolver
        for (m in plan.createEvents) runCatching {
            val values = mirrorValues(m, own = true).apply { put(CalendarContract.Events.CALENDAR_ID, calendarId) }
            resolver.insert(asSyncAdapter(CalendarContract.Events.CONTENT_URI), values)?.let { created[m.uuid] = ContentUris.parseId(it).toString() }
        }
        val ownIds = ownEvents(Long.MIN_VALUE..Long.MAX_VALUE).first.map { it.id }.toSet()
        for ((eventId, m) in plan.updateEvents) runCatching {
            val own = eventId in ownIds
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId.toLong())
            resolver.update(if (own) asSyncAdapter(uri) else uri, mirrorValues(m, own), null, null)
        }
        for (eventId in plan.deleteEventIds) runCatching {
            resolver.delete(asSyncAdapter(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId.toLong())), null, null)
        }
        created
    }

    private fun mirrorValues(m: com.lodo.app.core.CalendarTaskMirror, own: Boolean) = android.content.ContentValues().apply {
        put(CalendarContract.Events.TITLE, m.title)
        if (m.allDay) {
            // 全天事件必须按 UTC 0 点存,结束是下一天 0 点。
            val day = Instant.ofEpochMilli(m.start).atZone(ZoneId.systemDefault()).toLocalDate()
            put(CalendarContract.Events.DTSTART, day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
            put(CalendarContract.Events.DTEND, day.plusDays(1).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
            put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
            put(CalendarContract.Events.ALL_DAY, 1)
        } else {
            put(CalendarContract.Events.DTSTART, m.start)
            put(CalendarContract.Events.DTEND, m.end)
            put(CalendarContract.Events.EVENT_TIMEZONE, ZoneId.systemDefault().id)
            put(CalendarContract.Events.ALL_DAY, 0)
        }
        if (own) {
            put(CalendarContract.Events.CUSTOM_APP_PACKAGE, context.packageName)
            put(CalendarContract.Events.CUSTOM_APP_URI, m.eventUri)
        }
    }

    /** 关掉写开关时把 lodo 写过的事件连同那本日历一起清掉(留一堆孤儿事件比不同步更糟)。 */
    suspend fun removeOwnCalendar() = withContext(Dispatchers.IO) {
        val id = ownCalendarId() ?: return@withContext
        runCatching {
            context.contentResolver.delete(asSyncAdapter(ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, id)), null, null)
        }
    }

    companion object {
        const val OWN_CALENDAR_TITLE = "lodo"
        private const val OWN_ACCOUNT = "lodo"
        private val EVENT_PROJECTION = arrayOf(
            CalendarContract.Events._ID, CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND, CalendarContract.Events.ALL_DAY, CalendarContract.Events.CUSTOM_APP_URI,
        )

        /** 全天事件存的是 UTC 0 点,换成本地那一天的 0 点。 */
        fun utcDayToLocal(ms: Long): Long =
            Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
    }
}
