package com.lodo.app

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.ui.MainScreen
import com.lodo.app.ui.theme.LodoTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    /** 上次全量重排时间,30 秒内重复 resume 不再触发(对应 iOS 的前台节流)。 */
    private var lastSyncMillis = 0L

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= 33) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        consumeRouteIntent(intent)
        setContent {
            LodoTheme {
                MainScreen()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumeRouteIntent(intent)
    }

    /** App Shortcuts / 通知"改期"按钮写入的"route" extra,交给 Compose 层
     * (TodoListScreen)消费。 */
    private fun consumeRouteIntent(intent: Intent) {
        val app = application as LodoApp
        when (intent.getStringExtra("route")) {
            "agent" -> app.pendingRoute.value = PendingRoute.Agent(autoStart = false)
            "add" -> app.pendingRoute.value = PendingRoute.Agent(autoStart = true)
            "reschedule" -> intent.getStringExtra(AlarmScheduler.EXTRA_UUID)?.let { uuid ->
                app.pendingRoute.value = PendingRoute.Reschedule(uuid)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // 对应 iOS 回前台 refreshAll:重排全部待办闹钟与每日汇总(30 秒节流)
        val now = System.currentTimeMillis()
        if (now - lastSyncMillis < 30_000) return
        lastSyncMillis = now
        val app = application as LodoApp
        lifecycleScope.launch { app.repository.syncAlarms() }
    }
}
