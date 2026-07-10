package com.lodo.app.ui.settings

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.ai.DurationMemory
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

    /** AI 记忆文件内容(编辑对话框用)。 */
    var memoryText by mutableStateOf("")

    init {
        viewModelScope.launch {
            apiKey = app.settings.apiKey() ?: ""
            keySaved = apiKey.isNotEmpty()
        }
        memoryText = DurationMemory.content(app) ?: ""
    }

    fun setSnoozeMinutes(value: Int) = viewModelScope.launch {
        app.settings.setSnoozeMinutes(value.coerceIn(1, 240))
    }

    fun setAllDayTime(hhmm: String) = viewModelScope.launch {
        app.settings.setAllDayTime(hhmm)
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

    fun setInsightEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setInsightEnabled(enabled)
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
        app.settings.saveApiKey(apiKey)
        keySaved = true
    }
}
