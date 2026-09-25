package com.lodo.app.ui.settings

import android.app.Application
import android.net.Uri
import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.os.LocaleListCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.ai.DurationMemory
import com.lodo.app.ai.GeminiNanoClient
import com.lodo.app.ai.WebSearchClient
import com.lodo.app.data.Backup
import com.lodo.app.data.Settings
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SettingsViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp

    val settings = app.settings.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), Settings())

    var apiKey by mutableStateOf("")
    var keySaved by mutableStateOf(false)
        private set

    /** 联网搜索(Tavily)key,存取复用 apiKey(provider)/saveApiKey 那一套。 */
    var tavilyKey by mutableStateOf("")
    var tavilyKeySaved by mutableStateOf(false)
        private set

    /** AI 记忆文件内容(编辑对话框用)。 */
    var memoryText by mutableStateOf("")

    /** 端上 AI(Gemini Nano)可用性探测,对应 iOS Foundation Models 的
     * availability 检查——null=未测过,不主动在 app 启动时测(探测本身要真的
     * 跑一次推理,有成本),用户点"检测"才测一次。 */
    var geminiNanoAvailable by mutableStateOf<Boolean?>(null)
        private set
    var geminiNanoChecking by mutableStateOf(false)
        private set

    fun checkGeminiNanoAvailability() = viewModelScope.launch {
        geminiNanoChecking = true
        geminiNanoAvailable = GeminiNanoClient.isAvailable(app)
        geminiNanoChecking = false
    }

    /** 全量备份导入/导出的进行中状态与结果提示,对应 iOS 的备份导入导出。 */
    var backupBusy by mutableStateOf(false)
        private set
    var backupMessage by mutableStateOf<String?>(null)

    fun exportBackup(uri: Uri) = viewModelScope.launch {
        backupBusy = true
        backupMessage = null
        try {
            Backup.export(app, uri, app.database)
            backupMessage = "已导出备份。"
        } catch (e: Exception) {
            backupMessage = "导出失败:${e.message}"
        } finally {
            backupBusy = false
        }
    }

    fun importBackup(uri: Uri) = viewModelScope.launch {
        backupBusy = true
        backupMessage = null
        try {
            val result = Backup.import(app, uri, app.database)
            backupMessage = "已导入 ${result.taskCount} 项待办、${result.memoryCount} 条记忆、" +
                "${result.relationshipCount} 条人脉关系。"
        } catch (e: Exception) {
            backupMessage = "导入失败:${e.message}"
        } finally {
            backupBusy = false
        }
    }

    init {
        viewModelScope.launch {
            apiKey = app.settings.apiKey() ?: ""
            keySaved = apiKey.isNotEmpty()
            tavilyKey = app.settings.apiKey(WebSearchClient.PROVIDER_NAME) ?: ""
            tavilyKeySaved = tavilyKey.isNotEmpty()
        }
        memoryText = DurationMemory.content(app) ?: ""
    }

    /** 切换服务商:载入该服务商已存的 key,清掉模型覆盖值。 */
    fun setAiProvider(provider: String) = viewModelScope.launch {
        app.settings.setAiProvider(provider)
        app.settings.setAiModel("")
        apiKey = app.settings.apiKey(provider) ?: ""
        keySaved = apiKey.isNotEmpty()
    }

    fun setAiModel(model: String) = viewModelScope.launch {
        app.settings.setAiModel(model)
    }

    fun setAiCustomEndpoint(endpoint: String) = viewModelScope.launch {
        app.settings.setAiCustomEndpoint(endpoint)
    }

    fun setPersonaStyle(style: String) = viewModelScope.launch {
        app.settings.setPersonaStyle(style)
    }

    fun setPersonaCustom(text: String) = viewModelScope.launch {
        app.settings.setPersonaCustom(text)
    }

    fun setThinkingLevel(level: String) = viewModelScope.launch {
        app.settings.setThinkingLevel(level)
    }

    fun setSnoozeMinutes(value: Int) = viewModelScope.launch {
        app.settings.setSnoozeMinutes(value.coerceIn(1, 240))
    }

    fun setAllDayTime(hhmm: String) = viewModelScope.launch {
        app.settings.setAllDayTime(hhmm)
    }

    /** 「反复提醒」开关变更后重排闹钟:关掉时要把已经排出去的后续闹钟撤掉,
     * 打开时要把停住的事项重新接上(理由同下面免打扰那条)。 */
    fun setRepeatReminderEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setRepeatReminderEnabled(enabled)
        app.repository.syncAlarms()
    }

    /** 免打扰时段变更后重排所有待办的闹钟,让新设置立即生效(与 setDigestEnabled
     * 等汇总设置变更后 syncAlarms 的思路一致)。 */
    fun setQuietHoursEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setQuietHoursEnabled(enabled)
        app.repository.syncAlarms()
    }

    fun setQuietHoursStart(hhmm: String) = viewModelScope.launch {
        app.settings.setQuietHoursStart(hhmm)
        app.repository.syncAlarms()
    }

    fun setQuietHoursEnd(hhmm: String) = viewModelScope.launch {
        app.settings.setQuietHoursEnd(hhmm)
        app.repository.syncAlarms()
    }

    /** 汇总设置变更后立即重排汇总闹钟(对应 iOS refreshDigest)。 */
    fun setDigestEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setDigestEnabled(enabled)
        app.repository.syncAlarms()
    }

    fun setDigestTimes(times: List<String>) = viewModelScope.launch {
        app.settings.setDigestTimes(times)
        app.repository.syncAlarms()
    }

    fun setDigestRepeatType(type: String) = viewModelScope.launch {
        app.settings.setDigestRepeatType(type)
        app.repository.syncAlarms()
    }

    fun setDigestDays(days: List<Int>) = viewModelScope.launch {
        app.settings.setDigestDays(days)
        app.repository.syncAlarms()
    }

    fun setHapticsEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setHapticsEnabled(enabled)
    }

    /** 应用内语言开关,不跟随系统语言。两处真相要一起写:setLanguage 落 DataStore
     * 并同步 CurrentLang.value(core/ai/notify 包读这个显式状态);
     * AppCompatDelegate.setApplicationLocales 驱动 Compose UI 层的
     * stringResource()(内部会触发一次 Activity 重建,等价一次配置变更)。 */
    fun setLanguage(language: String) = viewModelScope.launch {
        app.settings.setLanguage(language)
        AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(language))
    }

    fun setInsightEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setInsightEnabled(enabled)
    }

    fun setAgentAutoRecordOnOpen(enabled: Boolean) = viewModelScope.launch {
        app.settings.setAgentAutoRecordOnOpen(enabled)
    }

    fun setAgentSilenceTimeoutSeconds(seconds: Int) = viewModelScope.launch {
        app.settings.setAgentSilenceTimeoutSeconds(seconds)
    }

    fun saveMemory() {
        DurationMemory.save(app, memoryText)
    }

    fun resetMemory() {
        DurationMemory.reset(app)
        memoryText = ""
    }

    fun reloadMemory() {
        memoryText = DurationMemory.content(app) ?: ""
    }

    fun onApiKeyChange(value: String) {
        apiKey = value
        keySaved = false
    }

    fun saveApiKey() = viewModelScope.launch {
        app.settings.saveApiKey(apiKey, settings.value.aiProvider)
        keySaved = true
    }

    fun onTavilyKeyChange(value: String) {
        tavilyKey = value
        tavilyKeySaved = false
    }

    fun saveTavilyKey() = viewModelScope.launch {
        app.settings.saveApiKey(tavilyKey, WebSearchClient.PROVIDER_NAME)
        tavilyKeySaved = true
    }
}
