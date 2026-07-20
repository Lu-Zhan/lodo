package com.lodo.app

import android.app.Application
import com.lodo.app.data.LodoDatabase
import com.lodo.app.data.SettingsRepository
import com.lodo.app.data.TaskRepository
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.notify.Notifications
import kotlinx.coroutines.flow.MutableStateFlow

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
        TaskRepository(this, database.taskDao(), settings, alarms)
    }

    val pendingRoute = MutableStateFlow<PendingRoute?>(null)

    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
    }
}
