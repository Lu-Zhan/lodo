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
import com.lodo.app.notify.NotificationPermission
import com.lodo.app.ui.AppShell
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.lodo.app.ui.theme.LodoTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    /** 上次全量重排时间,30 秒内重复 resume 不再触发(对应 iOS 的前台节流)。 */
    private var lastSyncMillis = 0L

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            val app = application as LodoApp
            lifecycleScope.launch { app.settings.setNotificationPermissionDenied(!granted) }
        }

    override fun attachBaseContext(newBase: android.content.Context) {
        if (android.os.Build.VERSION.SDK_INT < 33) {
            val lang = if (com.lodo.app.core.CurrentLang.value == com.lodo.app.core.Lang.EN) java.util.Locale.ENGLISH else java.util.Locale.SIMPLIFIED_CHINESE
            val config = android.content.res.Configuration(newBase.resources.configuration).apply { setLocale(lang) }
            super.attachBaseContext(newBase.createConfigurationContext(config))
        } else super.attachBaseContext(newBase)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // 已经授权时不再弹:每次启动都 launch 会拉起系统那个透明的授权 activity,
        // 抢走窗口焦点,导致启动后第一次点开的弹窗(导航栏、菜单)直接没反应(实测)。
        if (Build.VERSION.SDK_INT >= 33 && !NotificationPermission.isGranted(this)) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        consumeRouteIntent(intent)
        val app = application as LodoApp
        val initial = kotlinx.coroutines.runBlocking { app.settings.snapshot() }
        setContent {
            val settings by app.settings.settings.collectAsState(initial = initial)
            // Android 12 及以下没有按应用设置语言,语言靠 attachBaseContext 覆盖,只能重建一次。
            var shownLanguage by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(initial.language) }
            androidx.compose.runtime.LaunchedEffect(settings.language) {
                if (settings.language != shownLanguage) {
                    shownLanguage = settings.language
                    if (Build.VERSION.SDK_INT < 33) recreate()
                }
            }
            LodoTheme(accent = settings.accentPalette) {
                androidx.compose.material3.Surface(color = androidx.compose.material3.MaterialTheme.colorScheme.surface) {
                    AppShell(settings)
                }
            }
        }
    }

    /** 语言切换不重建 Activity(清单里声明了 configChanges),系统配置到位的这一刻再切界面上的
     * `L()` 文案——和 `stringResource` 同一帧换,不会先闪一帧中英混排。 */
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        com.lodo.app.ui.UiLang.current = com.lodo.app.core.CurrentLang.value
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumeRouteIntent(intent)
    }

    /** App Shortcuts / 通知"改期"按钮写入的"route" extra,交给 Compose 层
     * (TodoListScreen)消费;Google Assistant App Actions("创建待办"能力)
     * 走同一个 intent 分发点,携带"taskTitle" extra(见 shortcuts.xml 的
     * capability 声明)。 */
    private fun consumeRouteIntent(intent: Intent) {
        val app = application as LodoApp
        // 仅可调试版本:adb 传进来的 key 写进本机设置(加密存储),APK 里不内置任何 key。
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            intent.getStringExtra("debugApiKey")?.takeIf { it.isNotBlank() }?.let { key ->
                lifecycleScope.launch { app.settings.saveApiKey(key, app.settings.snapshot().aiProvider) }
            }
        }
        // 调试/深链:直接打开某个平级页面(值为 AppSection 名,如 TRAVEL)。
        intent.getStringExtra("section")?.let { app.pendingRoute.value = PendingRoute.Section(it) }
        when (intent.getStringExtra("route")) {
            "agent" -> app.pendingRoute.value = PendingRoute.Agent(autoStart = false)
            "add" -> app.pendingRoute.value = PendingRoute.Agent(autoStart = true)
            "reschedule" -> intent.getStringExtra(AlarmScheduler.EXTRA_UUID)?.let { uuid ->
                app.pendingRoute.value = PendingRoute.Reschedule(uuid)
            }
            "create_task" -> intent.getStringExtra("taskTitle")?.takeIf { it.isNotBlank() }?.let { title ->
                app.pendingRoute.value = PendingRoute.CreateTask(title)
            }
            "countdown" -> app.pendingRoute.value = PendingRoute.Section("COUNTDOWN")
            "tasks" -> app.pendingRoute.value = PendingRoute.Section("TASKS")
            "news" -> app.pendingRoute.value = PendingRoute.Section("NEWS")
        }
    }

    override fun onResume() {
        super.onResume()
        val app = application as LodoApp
        // 权限状态兜底同步:不管用户是在系统弹窗拒绝还是去系统设置手动切换,
        // 回前台都能拿到真实状态,不依赖一次性弹窗回调。查询本身很轻量,不节流。
        lifecycleScope.launch {
            app.settings.setNotificationPermissionDenied(!NotificationPermission.isGranted(this@MainActivity))
        }
        // 对应 iOS 回前台 refreshAll:重排全部待办闹钟与每日汇总(30 秒节流)
        val now = System.currentTimeMillis()
        if (now - lastSyncMillis < 30_000) return
        lastSyncMillis = now
        lifecycleScope.launch {
            app.repository.syncAlarms()
            runCatching { app.countdowns.reschedule() }
            runCatching { app.finance.syncReminders(app.repository, app.settings.snapshot().allDayTime) }
            runCatching { app.calendarSync.reconcile() }
        }
    }
}
