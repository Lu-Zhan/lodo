package com.lodo.app

import android.app.Application
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Lang
import com.lodo.app.data.LodoDatabase
import com.lodo.app.data.MemoryRepository
import com.lodo.app.data.RoutineRepository
import com.lodo.app.data.SettingsRepository
import com.lodo.app.data.TaskRepository
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.notify.Notifications
import com.lodo.app.notify.RoutineCheckWorker
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import java.util.concurrent.TimeUnit

/** App Shortcuts / 通知"改期"按钮等外部入口要打开的路由,对应 iOS 的
 * agentRequest 深链/Siri handoff 消费模式;MainActivity 写入,Compose 层消费后清空。 */
sealed interface PendingRoute {
    data class Agent(val autoStart: Boolean) : PendingRoute
    data class Reschedule(val uuid: String) : PendingRoute
    /** Google Assistant App Actions("创建待办"能力,与 iOS Siri AddTaskIntent
     * 对应)携带的事项标题,见 res/xml/shortcuts.xml 的 capability 声明。 */
    data class CreateTask(val title: String) : PendingRoute
    /** 打开某个平级页面(通知/小组件深链),值为 AppSection 名。 */
    data class Section(val name: String) : PendingRoute
}

/**
 * 应用内语言落到系统的「按应用设置语言」上:Android 13+ 直接走 LocaleManager(AppCompatDelegate
 * 在 ComponentActivity 上不生效,实测 get-app-locales 为空,界面一直跟着系统语言);
 * 12 及以下由 MainActivity.attachBaseContext 覆盖配置。
 */
fun applyAppLocale(context: android.content.Context, language: String) {
    if (android.os.Build.VERSION.SDK_INT >= 33) {
        val manager = context.getSystemService(android.app.LocaleManager::class.java) ?: return
        val wanted = android.os.LocaleList.forLanguageTags(if (language == "en") "en" else "zh-CN")
        if (manager.applicationLocales != wanted) manager.applicationLocales = wanted
    }
}

class LodoApp : Application() {
    val database: LodoDatabase by lazy { LodoDatabase.get(this) }
    val settings: SettingsRepository by lazy { SettingsRepository(this) }
    val alarms: AlarmScheduler by lazy { AlarmScheduler(this, settings) }
    val repository: TaskRepository by lazy {
        TaskRepository(this, database, settings, alarms)
    }
    val memoryRepository: MemoryRepository by lazy { MemoryRepository(database) }
    val routineRepository: RoutineRepository by lazy { RoutineRepository(this, database, settings) }
    val countdowns by lazy { com.lodo.app.data.CountdownRepository(this, database) }
    val finance by lazy { com.lodo.app.data.FinanceRepository(this, database) }
    val news by lazy { com.lodo.app.data.NewsRepository(this, database) }
    val travel by lazy { com.lodo.app.data.TravelRepository(database, memoryRepository) }
    val library by lazy { com.lodo.app.data.LibraryRepository(database, memoryRepository, news) }
    val menus by lazy { com.lodo.app.data.MenuRepository(database) }
    val health by lazy { com.lodo.app.data.HealthRepository(this) }
    val calendar by lazy { com.lodo.app.data.CalendarRepository(this) }
    val geocoder by lazy { com.lodo.app.data.TravelGeocoder(this, database) }
    val agent by lazy { com.lodo.app.data.AgentStore(this, database) }

    val pendingRoute = MutableStateFlow<PendingRoute?>(null)

    override fun onCreate() {
        super.onCreate()
        // 通知渠道创建/CurrentLang 初始化都要在第一次可能触发通知之前完成,
        // DataStore 读的是本机小文件,冷启动这一次性阻塞读可接受。
        val language = runBlocking { settings.snapshot() }.language
        CurrentLang.value = if (language == "en") Lang.EN else Lang.ZH
        // 新页面里的日期格式(星期几、月份名)跟应用内语言走,而不是系统语言。
        java.util.Locale.setDefault(if (language == "en") java.util.Locale.ENGLISH else java.util.Locale.SIMPLIFIED_CHINESE)
        // AppCompatDelegate 自己的 locale 状态不知道我们的 DataStore 存了什么,
        // 每次冷启动都要显式同步一次,否则 Compose UI 层的 stringResource()
        // 会先用系统语言渲染,直到用户下次手动切换设置才纠正过来。
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(language))
        applyAppLocale(this, language)
        Notifications.createChannels(this)
        val skillPrefs = getSharedPreferences("agent-skills", MODE_PRIVATE)
        com.lodo.app.ai.AgentSkillStore.init(
            filesDir,
            isEnabled = { skillPrefs.getBoolean(it, true) },
            setEnabled = { id, on -> skillPrefs.edit().putBoolean(id, on).apply() },
        )
        com.lodo.app.data.ExchangeRates.load(this)
        runCatching {
            val hantHans = android.icu.text.Transliterator.getInstance("Hant-Hans")
            com.lodo.app.core.OSMGeocode.toSimplified = { text -> synchronized(hantHans) { hantHans.transliterate(text) } }
        }
        scheduleRoutineCheck()
    }

    /** 定时任务(AI 例行任务)的周期性检查,15 分钟是 WorkManager 允许的最小
     * 周期间隔;KEEP 策略——已经排过就不重新排,避免每次冷启动打断正在计时的
     * 周期。 */
    private fun scheduleRoutineCheck() {
        val request = PeriodicWorkRequestBuilder<RoutineCheckWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "routine-check", ExistingPeriodicWorkPolicy.KEEP, request,
        )
    }
}
