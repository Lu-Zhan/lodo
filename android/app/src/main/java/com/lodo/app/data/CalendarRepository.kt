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
        )
        val result = mutableListOf<CalendarEvent>()
        runCatching {
            context.contentResolver.query(uri, projection, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
                while (c.moveToNext()) {
                    val allDay = c.getInt(4) == 1
                    // 全天日程在库里按 UTC 存,按 UTC 解出日期再落到本地 0 点。
                    fun time(ms: Long) = if (allDay) LocalDateTime.ofInstant(Instant.ofEpochMilli(ms), ZoneOffset.UTC)
                    else LocalDateTime.ofInstant(Instant.ofEpochMilli(ms), zone)
                    result += CalendarEvent(
                        eventId = c.getLong(0), title = c.getString(1) ?: "", start = time(c.getLong(2)),
                        end = time(c.getLong(3)), allDay = allDay, calendarName = c.getString(5) ?: "",
                        color = c.getInt(6), location = c.getString(7) ?: "",
                    )
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
}
