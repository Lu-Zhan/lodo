package com.lodo.app.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.lodo.app.MainActivity
import com.lodo.app.R
import com.lodo.app.core.TaskPhase
import com.lodo.app.data.TaskEntity

/** 通知渠道与通知构建;文案与 iOS NotificationManager 一致。 */
object Notifications {
    const val CHANNEL_REMINDERS = "reminders"
    const val CHANNEL_DIGEST = "digest"
    private const val DIGEST_ID = 1

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_REMINDERS, "到期提醒", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "事项到期的纠缠式提醒" }
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_DIGEST, "每日待办汇总", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun notificationId(uuid: String): Int = uuid.hashCode()

    private fun canNotify(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
            context, Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

    /** 4 个预设说话风格各一套提醒文案模板(到点/该开始/时间到三阶段);
     * "默认"和"自定义"(自由文本、无法预先枚举模板)沿用原文案。通知是提前排的
     * 闹钟触发时现算,不会实时调用 AI,所以这里是本地写死的文案。 */
    private val reminderTemplates: Map<String, Triple<String, String, String>> = mapOf(
        "高效秘书" to Triple("到时间了,请处理。", "该开始了,请预留 %d 分钟。", "时间已到,请确认完成情况。"),
        "温柔陪伴" to Triple("到时间啦,别忘了哦~", "要开始啦~大概需要 %d 分钟,加油!", "时间到啦,完成了吗?"),
        "严格教练" to Triple("时间到了,马上行动!", "该开始了!给自己 %d 分钟,专注去做。", "时间到,完成了没有?"),
        "幽默轻松" to Triple("叮!你的专属提醒到啦~", "开工时间到~预计 %d 分钟,冲鸭!", "时间到啦,搞定了没?别偷懒哦~"),
    )

    private fun reminderBody(
        personaStyle: String, starting: Boolean, isEnd: Boolean, durationMinutes: Int,
    ): String {
        val template = reminderTemplates[personaStyle] ?: return when {
            starting -> "该开始了!(时长 $durationMinutes 分钟)"
            isEnd -> "时间到 — 完成了吗?"
            else -> "到时间了"
        }
        return when {
            starting -> template.second.format(durationMinutes)
            isEnd -> template.third
            else -> template.first
        }
    }

    /** 到期提醒:带 完成/稍等一会 动作按钮,点通知本体打开 app。 */
    fun showTask(context: Context, task: TaskEntity, personaStyle: String = "默认") {
        if (!canNotify(context)) return
        val starting = task.phaseEnum == TaskPhase.START && task.durationMinutes > 0
        val body = reminderBody(personaStyle, starting, task.phaseEnum == TaskPhase.END, task.durationMinutes)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), flags
        )
        val doneIntent = PendingIntent.getBroadcast(
            context, notificationId(task.uuid),
            Intent(context, ActionReceiver::class.java)
                .setAction(ActionReceiver.ACTION_DONE)
                .putExtra(AlarmScheduler.EXTRA_UUID, task.uuid),
            flags,
        )
        val snoozeIntent = PendingIntent.getBroadcast(
            context, notificationId(task.uuid),
            Intent(context, ActionReceiver::class.java)
                .setAction(ActionReceiver.ACTION_SNOOZE)
                .putExtra(AlarmScheduler.EXTRA_UUID, task.uuid),
            flags,
        )
        // "改期"要打开 UI(改期候选需要联网请求+展示),不像完成/稍等能在后台
        // 广播里静默处理,所以直接 getActivity 打开 App 并带上 uuid,由
        // MainActivity 转成 PendingRoute.Reschedule 交给 Compose 层消费。
        val rescheduleIntent = PendingIntent.getActivity(
            context, notificationId(task.uuid),
            Intent(context, MainActivity::class.java)
                .setAction("com.lodo.app.action.RESCHEDULE")
                .putExtra("route", "reschedule")
                .putExtra(AlarmScheduler.EXTRA_UUID, task.uuid),
            flags,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDERS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(task.title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .addAction(0, "完成", doneIntent)
            .addAction(0, "稍等一会", snoozeIntent)
            .addAction(0, "改期", rescheduleIntent)
            .build()
        NotificationManagerCompat.from(context).notify(notificationId(task.uuid), notification)
    }

    /** 待办汇总:正文在触发时现算(今天事项的 AI 一句话概括或机械列表)。 */
    fun showDigest(context: Context, body: String) {
        if (!canNotify(context)) return
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), flags
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_DIGEST)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("每日待办汇总")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(DIGEST_ID, notification)
    }

    fun dismiss(context: Context, uuid: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(uuid))
    }
}
