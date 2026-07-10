package com.lodo.app.notify

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.Settings
import com.lodo.app.data.toEpochMillis
import java.time.LocalDateTime

/**
 * 精确闹钟调度。与 iOS 预排 8 条通知链不同,Android 闹钟触发时能执行代码:
 * ReminderReceiver 收到闹钟后发通知、把 nextRemindAt 顺延一个稍等间隔、再排下一个闹钟,
 * 纠缠式提醒因此自我延续——每个事项任一时刻只挂一个待触发闹钟。
 */
class AlarmScheduler(private val context: Context) {
    companion object {
        const val ACTION_REMIND = "com.lodo.app.action.REMIND"
        const val ACTION_DIGEST = "com.lodo.app.action.DIGEST"
        const val EXTRA_UUID = "uuid"
        private const val DIGEST_REQUEST_CODE = 0
        private const val FALLBACK_WINDOW_MILLIS = 10 * 60_000L
    }

    private val alarmManager = context.getSystemService(AlarmManager::class.java)

    fun scheduleReminder(uuid: String, at: LocalDateTime) {
        scheduleAt(reminderIntent(uuid), at.toEpochMillis())
    }

    fun cancelReminder(uuid: String) {
        alarmManager.cancel(reminderIntent(uuid))
    }

    /**
     * 排下一次汇总:在 时间点 ×(每天 / 每周选中周几)里找最近的未来时刻;
     * 触发后由 ReminderReceiver 再排下一次(自我延续)。
     */
    fun scheduleDigest(settings: Settings) {
        val now = LocalDateTime.now()
        val times = settings.digestTimes.map(TimeFormat::localTime)
        if (times.isEmpty()) {
            cancelDigest()
            return
        }
        val weekly = settings.digestRepeatType == "weekly"
        // 项目约定 0=周一 … 6=周日 → DayOfWeek 1=周一 … 7=周日
        val days = settings.digestDays.map { it + 1 }.toSet()
        for (offset in 0..7L) {
            val date = now.toLocalDate().plusDays(offset)
            if (weekly && date.dayOfWeek.value !in days) continue
            val next = times.map(date::atTime).filter { it.isAfter(now) }.minOrNull() ?: continue
            scheduleAt(digestIntent(), next.toEpochMillis())
            return
        }
        cancelDigest()
    }

    fun cancelDigest() {
        alarmManager.cancel(digestIntent())
    }

    private fun scheduleAt(intent: PendingIntent, triggerAtMillis: Long) {
        // 12/12L 上 SCHEDULE_EXACT_ALARM 可被用户关闭,降级为 10 分钟窗口的非精确闹钟
        if (Build.VERSION.SDK_INT < 31 || alarmManager.canScheduleExactAlarms()) {
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, intent)
        } else {
            alarmManager.setWindow(
                AlarmManager.RTC_WAKEUP, triggerAtMillis, FALLBACK_WINDOW_MILLIS, intent
            )
        }
    }

    private fun reminderIntent(uuid: String): PendingIntent = PendingIntent.getBroadcast(
        context, uuid.hashCode(),
        Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION_REMIND)
            .putExtra(EXTRA_UUID, uuid),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun digestIntent(): PendingIntent = PendingIntent.getBroadcast(
        context, DIGEST_REQUEST_CODE,
        Intent(context, ReminderReceiver::class.java).setAction(ACTION_DIGEST),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
