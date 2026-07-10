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
    /** 汇总提醒时间点列表("HH:MM"),无新值时迁移旧的单一 digestTime。 */
    val digestTimes: List<String> = listOf("21:00"),
    /** 汇总重复方式:"daily" 或 "weekly"。 */
    val digestRepeatType: String = "daily",
    /** weekly 时选中的周几(0=周一 … 6=周日),默认工作日。 */
    val digestDays: List<Int> = listOf(0, 1, 2, 3, 4),
    /** 滑动操作振动反馈,默认开。 */
    val hapticsEnabled: Boolean = true,
    /** 已完成页的每周完成洞察,默认开。 */
    val insightEnabled: Boolean = true,
)

/** 应用设置(Preferences DataStore);API key 经 AndroidKeyStore 加密后存储,对应 iOS 钥匙串。 */
class SettingsRepository(private val context: Context) {
    private object Keys {
        val SNOOZE_MINUTES = intPreferencesKey("snoozeMinutes")
        val ALL_DAY_TIME = stringPreferencesKey("allDayTime")
        val DIGEST_ENABLED = booleanPreferencesKey("digestEnabled")
        val DIGEST_TIME = stringPreferencesKey("digestTime")
        val DIGEST_TIMES = stringPreferencesKey("digestTimes")
        val DIGEST_REPEAT_TYPE = stringPreferencesKey("digestRepeatType")
        val DIGEST_DAYS = stringPreferencesKey("digestDays")
        val HAPTICS_ENABLED = booleanPreferencesKey("hapticsEnabled")
        val INSIGHT_ENABLED = booleanPreferencesKey("insightEnabled")
        val API_KEY_ENCRYPTED = stringPreferencesKey("apiKeyEncrypted")
    }

    val settings: Flow<Settings> = context.dataStore.data.map { p ->
        val digestTime = p[Keys.DIGEST_TIME] ?: "21:00"
        val digestTimes = (p[Keys.DIGEST_TIMES] ?: "")
            .split(",").filter { it.isNotBlank() }
            .ifEmpty { listOf(digestTime) }
        Settings(
            snoozeMinutes = (p[Keys.SNOOZE_MINUTES] ?: 0).takeIf { it > 0 } ?: 15,
            allDayTime = p[Keys.ALL_DAY_TIME] ?: "09:00",
            digestEnabled = p[Keys.DIGEST_ENABLED] ?: false,
            digestTime = digestTime,
            digestTimes = digestTimes,
            digestRepeatType = p[Keys.DIGEST_REPEAT_TYPE] ?: "daily",
            digestDays = (p[Keys.DIGEST_DAYS] ?: "0,1,2,3,4")
                .split(",").mapNotNull { it.toIntOrNull() }.filter { it in 0..6 }.sorted(),
            hapticsEnabled = p[Keys.HAPTICS_ENABLED] ?: true,
            insightEnabled = p[Keys.INSIGHT_ENABLED] ?: true,
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

    suspend fun setDigestTimes(times: List<String>) {
        context.dataStore.edit { it[Keys.DIGEST_TIMES] = times.joinToString(",") }
    }

    suspend fun setDigestRepeatType(type: String) {
        context.dataStore.edit { it[Keys.DIGEST_REPEAT_TYPE] = type }
    }

    suspend fun setDigestDays(days: List<Int>) {
        context.dataStore.edit { it[Keys.DIGEST_DAYS] = days.sorted().joinToString(",") }
    }

    suspend fun setHapticsEnabled(enabled: Boolean) {
        context.dataStore.edit { it[Keys.HAPTICS_ENABLED] = enabled }
    }

    suspend fun setInsightEnabled(enabled: Boolean) {
        context.dataStore.edit { it[Keys.INSIGHT_ENABLED] = enabled }
    }

    suspend fun apiKey(): String? =
        context.dataStore.data.first()[Keys.API_KEY_ENCRYPTED]?.let { KeystoreCipher.decrypt(it) }

    suspend fun saveApiKey(key: String) {
        context.dataStore.edit { it[Keys.API_KEY_ENCRYPTED] = KeystoreCipher.encrypt(key) }
    }
}
