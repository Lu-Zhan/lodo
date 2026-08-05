package com.lodo.app

import android.app.Application
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Lang
import com.lodo.app.data.LodoDatabase
import com.lodo.app.data.SettingsRepository
import com.lodo.app.data.TaskRepository
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.notify.Notifications
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking

/** App Shortcuts / 通知"改期"按钮等外部入口要打开的路由,对应 iOS 的
 * agentRequest 深链/Siri handoff 消费模式;MainActivity 写入,Compose 层消费后清空。 */
sealed interface PendingRoute {
    data class Agent(val autoStart: Boolean) : PendingRoute
    data class Reschedule(val uuid: String) : PendingRoute
}

class LodoApp : Application() {
    val database: LodoDatabase by lazy { LodoDatabase.get(this) }
    val settings: SettingsRepository by lazy { SettingsRepository(this) }
    val alarms: AlarmScheduler by lazy { AlarmScheduler(this) }
    val repository: TaskRepository by lazy {
        TaskRepository(this, database, settings, alarms)
    }

    val pendingRoute = MutableStateFlow<PendingRoute?>(null)

    override fun onCreate() {
        super.onCreate()
        // 通知渠道创建/CurrentLang 初始化都要在第一次可能触发通知之前完成,
        // DataStore 读的是本机小文件,冷启动这一次性阻塞读可接受。
        val language = runBlocking { settings.snapshot() }.language
        CurrentLang.value = if (language == "en") Lang.EN else Lang.ZH
        // AppCompatDelegate 自己的 locale 状态不知道我们的 DataStore 存了什么,
        // 每次冷启动都要显式同步一次,否则 Compose UI 层的 stringResource()
        // 会先用系统语言渲染,直到用户下次手动切换设置才纠正过来。
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(language))
        Notifications.createChannels(this)
    }
}
