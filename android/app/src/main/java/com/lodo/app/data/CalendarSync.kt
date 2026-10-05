package com.lodo.app.data

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.CalendarSyncPlanner
import com.lodo.app.core.CalendarSyncRecord
import com.lodo.app.core.CalendarTaskMirror
import com.lodo.app.core.SyncEvent

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.time.Instant
import java.time.ZoneId

/**
 * 任务 ⇄ lodo 那本日历的双向对账执行者,对应 iOS `CalendarSync`。判断全在纯函数
 * `core.CalendarSyncPlanner`,这里只把 plan 落到两边。几条和 iOS 一样定死的:
 * - 整套受写开关门控(`calendarWriteEnabled`),只读展示不建账本也不改任务;
 * - 整本对账,不逐处挂钩子:未完成任务一变(Room 的 Flow)、日历一变(ContentObserver)、
 *   回前台,都合并成一次 `reconcile`;
 * - 账本(`calendar-sync.json`)不跨设备,事件 id 是本机的;关开关时账本连同那本日历一起清;
 * - 回写任务走 `applyEdit`(和表单保存同一条路,重排提醒);日历里删掉事件 = 删掉任务。
 */
class CalendarSync(private val context: Context, private val app: com.lodo.app.LodoApp) {
    private val mutex = Mutex()
    private var pending: Job? = null
    /** 正在把 plan 落到任务这一侧:回写会让任务 Flow 再发一次,不挡住会把刚回写的改动当成任务改了。 */
    @Volatile private var applying = false
    private val ledgerFile get() = File(context.filesDir, "calendar-sync.json")

    private fun loadLedger(): List<CalendarSyncRecord> =
        runCatching { CalendarSyncRecord.decode(ledgerFile.readText()) }.getOrDefault(emptyList())
    private fun saveLedger(r: List<CalendarSyncRecord>) = runCatching { ledgerFile.writeText(CalendarSyncRecord.encode(r)) }

    /** 进程启动时挂上:写开关和未完成任务的变化、系统日历的变化都会触发一次(去抖后)对账。 */
    fun start(scope: CoroutineScope) {
        scope.launch {
            combine(
                app.settings.settings.map { it.calendarWriteEnabled }.distinctUntilChanged(),
                app.database.taskDao().observePending(),
            ) { on, _ -> on }.collect { on -> if (on) request(scope) }
        }
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { request(scope) }
        }
        runCatching { context.contentResolver.registerContentObserver(CalendarContract.Events.CONTENT_URI, true, observer) }
    }

    fun request(scope: CoroutineScope) {
        if (applying) return
        pending?.cancel()
        pending = scope.launch { delay(600); reconcile() }
    }

    suspend fun reconcile() = mutex.withLock {
        val settings = app.settings.snapshot()
        if (!settings.calendarEnabled || !settings.calendarWriteEnabled || !app.calendar.hasWritePermission()) return@withLock
        val zone = ZoneId.systemDefault()
        val now = System.currentTimeMillis()
        val window = (now - 7 * DAY)..(now + 90 * DAY)
        val tasks = app.database.taskDao().pending()
        val mirrors = tasks.mapNotNull { t ->
            CalendarTaskMirror.from(t.uuid, t.title, true, t.isRecurring, t.remindAtMillis, t.nextRemindAtMillis, t.durationMinutes, t.allDay)
                ?.let { m ->
                    // 全天事项在日历里按整天存(读回来是本地 0 点到次日 0 点),镜像也按整天比,不然每轮都"变了"。
                    if (!m.allDay) m else {
                        val day = Instant.ofEpochMilli(m.start).atZone(zone).toLocalDate()
                        m.copy(start = day.atStartOfDay(zone).toInstant().toEpochMilli(),
                            end = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())
                    }
                }
        }.filter { it.start in window }
        val byUuid = tasks.associateBy { it.uuid }
        val records = loadLedger()
        val (own, claimed) = app.calendar.ownEvents(window)
        val foreign = app.calendar.eventsWithIds(records.filter { !it.ownCalendar }.map { it.eventId })
        val plan = CalendarSyncPlanner.plan(records, mirrors, own + foreign, claimed, window)
        if (plan.isEmpty && plan.records == records) return@withLock

        applying = true
        try {
            val created = app.calendar.apply(plan)
            for (u in plan.updateTasks) {
                val t = byUuid[u.uuid] ?: continue
                val start = Instant.ofEpochMilli(u.start).atZone(zone).toLocalDateTime()
                // 全天的只换日子,保留任务原来的提醒时刻。
                val remindAt = if (u.allDay) start.toLocalDate().atTime(t.remindAt.toLocalTime()) else start
                app.repository.applyEdit(u.uuid, ParsedTask(
                    u.title, remindAt, u.allDay, if (u.allDay) t.durationMinutes else u.durationMinutes,
                    t.repeatTypeEnum, t.repeatDaysList, t.repeatTimesList, t.project,
                ))
            }
            for (uuid in plan.deleteTaskUuids) app.repository.delete(uuid)
            val ledger = plan.records.toMutableList()
            for (m in plan.createEvents) created[m.uuid]?.let { ledger += CalendarSyncRecord.from(m, it, true) }
            saveLedger(ledger)
        } finally {
            delay(800)   // 让自己写出去的那一波 Flow/ContentObserver 通知先过去
            applying = false
        }
    }

    /** 「转为任务」认领别人家日历的一条:记进账本(own = false),从此双向,但删任务不删人家的日程。 */
    suspend fun claim(event: CalendarEvent, taskUuid: String) = mutex.withLock {
        if (!app.settings.snapshot().calendarWriteEnabled) return@withLock
        val e = SyncEvent(event.eventId.toString(), event.title,
            if (event.allDay) CalendarRepository.utcDayToLocal(event.beginMillis) else event.start.toEpochMillis(),
            if (event.allDay) CalendarRepository.utcDayToLocal(event.endMillis) else event.end.toEpochMillis(), event.allDay)
        saveLedger(loadLedger() + CalendarSyncRecord.from(e, taskUuid, false))
    }

    /** 关掉写开关:清账本、删掉 lodo 那本日历(连同镜像事件)。 */
    suspend fun disable() = mutex.withLock {
        ledgerFile.delete()
        app.calendar.removeOwnCalendar()
    }

    private companion object { const val DAY = 86_400_000L }
}
