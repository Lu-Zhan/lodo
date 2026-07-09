package com.lodo.app

import android.app.Application
import com.lodo.app.data.LodoDatabase
import com.lodo.app.data.SettingsRepository
import com.lodo.app.data.TaskRepository
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.notify.Notifications

class LodoApp : Application() {
    val database: LodoDatabase by lazy { LodoDatabase.get(this) }
    val settings: SettingsRepository by lazy { SettingsRepository(this) }
    val alarms: AlarmScheduler by lazy { AlarmScheduler(this) }
    val repository: TaskRepository by lazy {
        TaskRepository(this, database.taskDao(), settings, alarms)
    }

    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
    }
}
