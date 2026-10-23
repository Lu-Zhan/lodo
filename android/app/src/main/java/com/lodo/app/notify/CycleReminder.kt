package com.lodo.app.notify

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.lodo.app.LodoApp
import com.lodo.app.MainActivity
import com.lodo.app.R
import com.lodo.app.core.CyclePlan
import com.lodo.app.core.CyclePrediction
import com.lodo.app.data.toEpochMillis
import kotlinx.coroutines.*
import java.time.LocalDateTime

/** 经期预测是一次性提醒,不是纠缠待办;触发前按最新记录/开关再核对一遍。 */
object CycleReminder {
    private const val REQUEST = 0x4359434c
    private fun pending(context: Context, at: Long = 0) = PendingIntent.getBroadcast(context, REQUEST,
        Intent(context, CycleReminderReceiver::class.java).setAction("com.lodo.CYCLE_REMINDER").putExtra("at", at),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    suspend fun prediction(app: LodoApp, now: LocalDateTime): CyclePrediction.Result = CyclePrediction.predict(
        CyclePlan.merge(app.database.healthDao().periods().map { it.entry() }, emptyList(), now.toLocalDate()), now.toLocalDate(), app.healthJournal.confirmations())
    suspend fun reschedule(app: LodoApp) {
        val alarm = app.getSystemService(AlarmManager::class.java)
        val now = LocalDateTime.now()
        val prediction = if (app.healthJournal.cycleEnabled && app.healthJournal.cycleReminderEnabled) prediction(app, now) else null
        val at = prediction?.let { CyclePrediction.reminderDate(it, app.settings.snapshot().allDayTime, now) }?.toEpochMillis()
        alarm.cancel(pending(app))
        if (at == null) return
        if (alarm.canScheduleExactAlarms()) alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(app, at))
        else alarm.setWindow(AlarmManager.RTC_WAKEUP, at, 10 * 60000, pending(app, at))
    }
    suspend fun fire(app: LodoApp, expectedAt: Long) {
        val j = app.healthJournal
        if (!j.cycleEnabled || !j.cycleReminderEnabled || !NotificationPermission.isGranted(app)) return
        val now = LocalDateTime.now()
        val p = prediction(app, now)
        val at = CyclePrediction.reminderDate(p, app.settings.snapshot().allDayTime, now.minusDays(1))?.toEpochMillis()
        if (at != expectedAt || expectedAt > System.currentTimeMillis() || System.currentTimeMillis() - expectedAt > 24 * 60 * 60000L) return
        val window = p.nextStart ?: return
        val intent = PendingIntent.getActivity(app, REQUEST,
            Intent(app, MainActivity::class.java).putExtra("section", "HEALTH"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(app, Notifications.CHANNEL_REMINDERS).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("经期提醒").setContentText("预计 ${window.lower} — ${window.upper} 可能来月经,记得备好用品。")
            .setContentIntent(intent).setAutoCancel(true).build()
        NotificationManagerCompat.from(app).notify(REQUEST, notification)
    }
}
class CycleReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.lodo.CYCLE_REMINDER") return
        val result = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try { CycleReminder.fire(context.applicationContext as LodoApp, intent.getLongExtra("at", 0)) }
            finally { result.finish() }
        }
    }
}
