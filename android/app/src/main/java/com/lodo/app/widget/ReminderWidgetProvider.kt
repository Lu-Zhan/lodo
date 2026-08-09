package com.lodo.app.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import com.lodo.app.LodoApp
import com.lodo.app.R
import com.lodo.app.core.TimeFormat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * 到期提醒桌面小组件,对应 iOS LodoWidgetExtension 的"即将到来"快照——展示
 * 最近一条待办。系统自动按 [updatePeriodMillis](30 分钟,平台允许的最小值)
 * 刷新;这一轮 Android 没有像 iOS WidgetBridge.sync 那样"数据变更后主动推
 * 刷新"的实时联动(需要在 TaskRepository 每个写路径都插入一次小组件刷新
 * 调用,改动面较大),先用系统周期刷新打底,后续要补实时联动的话在
 * TaskRepository 的 complete/snooze/saveNew/applyEdit 里各加一行
 * `ReminderWidgetProvider.requestUpdate(context)` 即可。
 */
class ReminderWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetIds.forEach { id -> updateWidget(context, appWidgetManager, id) }
    }

    private fun updateWidget(context: Context, manager: AppWidgetManager, widgetId: Int) {
        CoroutineScope(Dispatchers.IO).launch {
            val app = context.applicationContext as LodoApp
            val next = app.database.taskDao().pending().minByOrNull { it.nextRemindAtMillis }
            val views = RemoteViews(context.packageName, R.layout.widget_reminder)
            if (next == null) {
                views.setTextViewText(R.id.widget_task_title, context.getString(R.string.android_ui_no_upcoming_reminders))
                views.setTextViewText(R.id.widget_task_time, "")
            } else {
                views.setTextViewText(R.id.widget_task_title, next.title)
                views.setTextViewText(R.id.widget_task_time, TimeFormat.format(next.nextRemindAt))
            }
            manager.updateAppWidget(widgetId, views)
        }
    }

    companion object {
        /** 数据变更后想立刻刷新小组件时调用(可选,见类注释)。 */
        fun requestUpdate(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                android.content.ComponentName(context, ReminderWidgetProvider::class.java)
            )
            if (ids.isNotEmpty()) {
                val intent = android.content.Intent(context, ReminderWidgetProvider::class.java)
                intent.action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                context.sendBroadcast(intent)
            }
        }
    }
}
