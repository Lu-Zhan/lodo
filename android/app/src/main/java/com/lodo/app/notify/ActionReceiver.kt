package com.lodo.app.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.lodo.app.LodoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** 通知上的 完成/稍等一会 按钮,与 app 内按钮走同一套 TaskRepository 逻辑。 */
class ActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_DONE = "com.lodo.app.action.DONE"
        const val ACTION_SNOOZE = "com.lodo.app.action.SNOOZE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as LodoApp
        val action = intent.action ?: return
        val uuid = intent.getStringExtra(AlarmScheduler.EXTRA_UUID) ?: return
        val result = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                when (action) {
                    ACTION_DONE -> app.repository.complete(uuid)
                    ACTION_SNOOZE -> app.repository.snooze(uuid)
                }
            } finally {
                result.finish()
            }
        }
    }
}
