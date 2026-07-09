package com.lodo.app.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.lodo.app.LodoApp
import com.lodo.app.core.Scheduler
import com.lodo.app.core.TaskStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.LocalDateTime

/** 闹钟触发:发提醒通知并把提醒链向后顺延一格;每日汇总触发时现算未完成数。 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as LodoApp
        val action = intent.action ?: return
        val uuid = intent.getStringExtra(AlarmScheduler.EXTRA_UUID)
        val result = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                when (action) {
                    AlarmScheduler.ACTION_REMIND -> uuid?.let { handleRemind(app, it) }
                    AlarmScheduler.ACTION_DIGEST -> handleDigest(app)
                }
            } finally {
                result.finish()
            }
        }
    }

    private suspend fun handleRemind(app: LodoApp, uuid: String) {
        val dao = app.database.taskDao()
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.PENDING) return
        val now = LocalDateTime.now()
        val data = entity.toData()
        if (data.isDue(now)) {
            Notifications.showTask(app, entity)
            // 忽略通知也会在稍等间隔后再次提醒(与 web 版 markNotified 语义一致)
            val notified = Scheduler.markNotified(data, now, app.settings.snapshot().snoozeMinutes)
            dao.upsert(entity.withData(notified))
            app.alarms.scheduleReminder(uuid, notified.nextRemindAt)
        } else {
            // 提前触发的陈旧闹钟:按当前 nextRemindAt 重排,不发通知
            app.alarms.scheduleReminder(uuid, data.nextRemindAt)
        }
    }

    private suspend fun handleDigest(app: LodoApp) {
        val settings = app.settings.snapshot()
        if (!settings.digestEnabled) return
        Notifications.showDigest(app, app.database.taskDao().pending().size)
        app.alarms.scheduleDigest(settings.digestTime)
    }
}
