package com.lodo.app

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
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
        setContent {
            LodoTheme {
                MainScreen()
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
