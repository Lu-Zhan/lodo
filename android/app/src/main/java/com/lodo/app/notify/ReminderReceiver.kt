package com.lodo.app.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.lodo.app.LodoApp
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.Scheduler
import com.lodo.app.core.TaskStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
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

    /** 汇总触发:现算今天开始/到期的事项,AI 一句话概括(限时,失败退回机械文案)。 */
    private suspend fun handleDigest(app: LodoApp) {
        val settings = app.settings.snapshot()
        if (!settings.digestEnabled) return
        val tomorrow = LocalDateTime.now().toLocalDate().plusDays(1).atStartOfDay()
        val today = app.database.taskDao().pending()
            .filter { it.nextRemindAt.isBefore(tomorrow) }
            .sortedBy { it.nextRemindAtMillis }
        val body = if (today.isEmpty()) {
            "今日暂无待办事项 🎉"
        } else {
            val items = today.map { task ->
                buildString {
                    append("${task.title}(${com.lodo.app.core.TimeFormat.format(task.nextRemindAt)}")
                    if (task.durationMinutes > 0) append(",${task.durationMinutes} 分钟")
                    append(")")
                }
            }
            withTimeoutOrNull(8_000) {
                runCatching {
                    DeepSeekClient.summarizeToday(app.settings.apiKey(), items)
                }.getOrNull()
            } ?: run {
                val shown = today.take(3).joinToString("、") { it.title }
                if (today.size > 3) "今天:$shown 等 ${today.size} 件"
                else "今天:$shown(共 ${today.size} 件)"
            }
        }
        Notifications.showDigest(app, body)
        app.alarms.scheduleDigest(settings)
    }
}
