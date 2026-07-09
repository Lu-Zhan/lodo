package com.lodo.app.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.lodo.app.ai.KeystoreCipher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "settings")

/** 应用设置快照,默认值与 iOS AppSettings / web settings.py 一致。 */
data class Settings(
    val snoozeMinutes: Int = 15,
    /** 全天(仅日期)事项当天的提醒时间,"HH:MM"。 */
    val allDayTime: String = "09:00",
    val digestEnabled: Boolean = false,
    val digestTime: String = "21:00",
)

/** 应用设置(Preferences DataStore);API key 经 AndroidKeyStore 加密后存储,对应 iOS 钥匙串。 */
class SettingsRepository(private val context: Context) {
    private object Keys {
        val SNOOZE_MINUTES = intPreferencesKey("snoozeMinutes")
        val ALL_DAY_TIME = stringPreferencesKey("allDayTime")
        val DIGEST_ENABLED = booleanPreferencesKey("digestEnabled")
        val DIGEST_TIME = stringPreferencesKey("digestTime")
        val API_KEY_ENCRYPTED = stringPreferencesKey("apiKeyEncrypted")
    }

    val settings: Flow<Settings> = context.dataStore.data.map { p ->
        Settings(
            snoozeMinutes = (p[Keys.SNOOZE_MINUTES] ?: 0).takeIf { it > 0 } ?: 15,
            allDayTime = p[Keys.ALL_DAY_TIME] ?: "09:00",
            digestEnabled = p[Keys.DIGEST_ENABLED] ?: false,
            digestTime = p[Keys.DIGEST_TIME] ?: "21:00",
        )
    }

    suspend fun snapshot(): Settings = settings.first()

    suspend fun setSnoozeMinutes(value: Int) {
        context.dataStore.edit { it[Keys.SNOOZE_MINUTES] = value }
    }

    suspend fun setAllDayTime(hhmm: String) {
        context.dataStore.edit { it[Keys.ALL_DAY_TIME] = hhmm }
    }

    suspend fun setDigestEnabled(enabled: Boolean) {
        context.dataStore.edit { it[Keys.DIGEST_ENABLED] = enabled }
    }

    suspend fun setDigestTime(hhmm: String) {
        context.dataStore.edit { it[Keys.DIGEST_TIME] = hhmm }
    }

    suspend fun apiKey(): String? =
        context.dataStore.data.first()[Keys.API_KEY_ENCRYPTED]?.let { KeystoreCipher.decrypt(it) }

    suspend fun saveApiKey(key: String) {
        context.dataStore.edit { it[Keys.API_KEY_ENCRYPTED] = KeystoreCipher.encrypt(key) }
    }
}
