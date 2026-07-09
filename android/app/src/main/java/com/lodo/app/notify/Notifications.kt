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

    /** 到期提醒:带 完成/稍等一会 动作按钮,点通知本体打开 app。 */
    fun showTask(context: Context, task: TaskEntity) {
        if (!canNotify(context)) return
        val starting = task.phaseEnum == TaskPhase.START && task.durationMinutes > 0
        val body = when {
            starting -> "该开始了!(时长 ${task.durationMinutes} 分钟)"
            task.phaseEnum == TaskPhase.END -> "时间到 — 完成了吗?"
            else -> "到时间了"
        }
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
        val notification = NotificationCompat.Builder(context, CHANNEL_REMINDERS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(task.title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .addAction(0, "完成", doneIntent)
            .addAction(0, "稍等一会", snoozeIntent)
            .build()
        NotificationManagerCompat.from(context).notify(notificationId(task.uuid), notification)
    }

    /** 每日待办汇总,数量在触发时现算。 */
    fun showDigest(context: Context, pendingCount: Int) {
        if (!canNotify(context)) return
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), flags
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_DIGEST)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("每日待办汇总")
            .setContentText(
                if (pendingCount > 0) "还有 $pendingCount 件事未完成,打开 lodo 查看"
                else "今日事项全部完成 🎉"
            )
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(DIGEST_ID, notification)
    }

    fun dismiss(context: Context, uuid: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(uuid))
    }
}
