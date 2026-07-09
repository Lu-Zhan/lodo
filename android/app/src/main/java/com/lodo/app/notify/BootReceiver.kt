package com.lodo.app.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.lodo.app.LodoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** 闹钟不跨重启:开机或应用更新后重排全部待办闹钟与每日汇总。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return
        val app = context.applicationContext as LodoApp
        val result = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                app.repository.syncAlarms()
            } finally {
                result.finish()
            }
        }
    }
}
