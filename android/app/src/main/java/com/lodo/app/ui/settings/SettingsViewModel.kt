package com.lodo.app.ui.settings

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
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

    init {
        viewModelScope.launch {
            apiKey = app.settings.apiKey() ?: ""
            keySaved = apiKey.isNotEmpty()
        }
    }

    fun setSnoozeMinutes(value: Int) = viewModelScope.launch {
        app.settings.setSnoozeMinutes(value.coerceIn(1, 240))
    }

    fun setAllDayTime(hhmm: String) = viewModelScope.launch {
        app.settings.setAllDayTime(hhmm)
    }

    /** 汇总开关/时间变更后立即重排每日汇总闹钟(对应 iOS refreshDigest)。 */
    fun setDigestEnabled(enabled: Boolean) = viewModelScope.launch {
        app.settings.setDigestEnabled(enabled)
        app.repository.syncAlarms()
    }

    fun setDigestTime(hhmm: String) = viewModelScope.launch {
        app.settings.setDigestTime(hhmm)
        app.repository.syncAlarms()
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
