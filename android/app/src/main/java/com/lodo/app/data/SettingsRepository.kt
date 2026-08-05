package com.lodo.app.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.lodo.app.ai.AIConfig
import com.lodo.app.ai.KeystoreCipher
import com.lodo.app.ai.WebSearchClient
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "settings")

/** AI 服务商预设(均为 OpenAI 兼容的 chat/completions 接口),与 iOS AppSettings 一致。 */
data class AIProviderPreset(val name: String, val endpoint: String, val model: String)

val aiProviderPresets = listOf(
    AIProviderPreset("DeepSeek", "https://api.deepseek.com/chat/completions", "deepseek-v4-flash"),
    AIProviderPreset("OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
    AIProviderPreset("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen-plus"),
    AIProviderPreset("Kimi", "https://api.moonshot.cn/v1/chat/completions", "moonshot-v1-8k"),
    AIProviderPreset("智谱", "https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash"),
)

/** AI 个性预设:名称 → 说话风格描述,与 iOS AppSettings.personaPresets 一致。 */
val personaPresets = listOf(
    "高效秘书" to "像一位干练的行政秘书:简洁、专业、直接,不说废话。",
    "温柔陪伴" to "语气温柔体贴,像关心你的朋友,多一点鼓励。",
    "严格教练" to "像自律教练:直接有推动力,催促按时完成,语气可以严厉但保持尊重。",
    "幽默轻松" to "轻松幽默,偶尔调皮,让提醒不那么无聊。",
)

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
    /** 点击添加弹出 AI 助手时自动开始语音,默认开。 */
    val agentAutoRecordOnOpen: Boolean = true,
    /** 语音输入静音多少秒后自动停止,默认 3 秒;0 = 关闭,不自动停止。 */
    val agentSilenceTimeoutSeconds: Int = 3,
    /** AI 服务商("自定义"用自定义端点),默认 DeepSeek。 */
    val aiProvider: String = "DeepSeek",
    /** 模型覆盖值,空=用服务商默认。 */
    val aiModel: String = "",
    val aiCustomEndpoint: String = "",
    /** AI 个性:"默认"=无个性,"自定义"用 personaCustom,其余取预设。 */
    val personaStyle: String = "默认",
    val personaCustom: String = "",
    /** AI 助手的思考强度:off/low/medium/high,默认 medium。只作用于 AI 助手
     * 对话入口,不影响解析/汇总等后台小请求。 */
    val thinkingLevel: String = "medium",
    /** 通知权限是否被拒绝(SDK<33 恒为 false),供待办列表顶部横幅展示。 */
    val notificationPermissionDenied: Boolean = false,
    /** 闹钟触发但因权限缺失未能展示通知的连续次数,展示成功后清零,
     * 用于计算重试退避间隔(见 NotifyBackoff)。 */
    val notifyMissCount: Int = 0,
    /** 应用内语言开关,不跟随系统语言,默认中文("zh"/"en")。 */
    val language: String = "zh",
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
        val AGENT_AUTO_RECORD_ON_OPEN = booleanPreferencesKey("agentAutoRecordOnOpen")
        val AGENT_SILENCE_TIMEOUT_SECONDS = intPreferencesKey("agentSilenceTimeoutSeconds")
        val AI_PROVIDER = stringPreferencesKey("aiProvider")
        val AI_MODEL = stringPreferencesKey("aiModel")
        val AI_CUSTOM_ENDPOINT = stringPreferencesKey("aiCustomEndpoint")
        val PERSONA_STYLE = stringPreferencesKey("agentPersonaStyle")
        val PERSONA_CUSTOM = stringPreferencesKey("agentPersonaCustom")
        val THINKING_LEVEL = stringPreferencesKey("thinkingLevel")
        val NOTIFICATION_PERMISSION_DENIED = booleanPreferencesKey("notificationPermissionDenied")
        val NOTIFY_MISS_COUNT = intPreferencesKey("notifyMissCount")
        val LANGUAGE = stringPreferencesKey("language")
        /** 旧版单一 DeepSeek key,读取时兼容。 */
        val API_KEY_ENCRYPTED = stringPreferencesKey("apiKeyEncrypted")

        fun apiKeyFor(provider: String) = stringPreferencesKey("apiKeyEncrypted_$provider")
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
            agentAutoRecordOnOpen = p[Keys.AGENT_AUTO_RECORD_ON_OPEN] ?: true,
            agentSilenceTimeoutSeconds = p[Keys.AGENT_SILENCE_TIMEOUT_SECONDS] ?: 3,
            aiProvider = p[Keys.AI_PROVIDER] ?: "DeepSeek",
            aiModel = p[Keys.AI_MODEL] ?: "",
            aiCustomEndpoint = p[Keys.AI_CUSTOM_ENDPOINT] ?: "",
            personaStyle = p[Keys.PERSONA_STYLE] ?: "默认",
            personaCustom = p[Keys.PERSONA_CUSTOM] ?: "",
            thinkingLevel = p[Keys.THINKING_LEVEL] ?: "medium",
            notificationPermissionDenied = p[Keys.NOTIFICATION_PERMISSION_DENIED] ?: false,
            notifyMissCount = p[Keys.NOTIFY_MISS_COUNT] ?: 0,
            language = p[Keys.LANGUAGE] ?: "zh",
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

    suspend fun setAgentAutoRecordOnOpen(enabled: Boolean) {
        context.dataStore.edit { it[Keys.AGENT_AUTO_RECORD_ON_OPEN] = enabled }
    }

    suspend fun setAgentSilenceTimeoutSeconds(seconds: Int) {
        context.dataStore.edit { it[Keys.AGENT_SILENCE_TIMEOUT_SECONDS] = seconds.coerceIn(0, 30) }
    }

    suspend fun setAiProvider(provider: String) {
        context.dataStore.edit { it[Keys.AI_PROVIDER] = provider }
    }

    suspend fun setAiModel(model: String) {
        context.dataStore.edit { it[Keys.AI_MODEL] = model }
    }

    suspend fun setAiCustomEndpoint(endpoint: String) {
        context.dataStore.edit { it[Keys.AI_CUSTOM_ENDPOINT] = endpoint }
    }

    suspend fun setPersonaStyle(style: String) {
        context.dataStore.edit { it[Keys.PERSONA_STYLE] = style }
    }

    suspend fun setPersonaCustom(text: String) {
        context.dataStore.edit { it[Keys.PERSONA_CUSTOM] = text }
    }

    suspend fun setThinkingLevel(level: String) {
        context.dataStore.edit { it[Keys.THINKING_LEVEL] = level }
    }

    /** 落 DataStore 同时同步 CurrentLang.value——core/ai/notify 包不能 import
     * Android Context,只能靠这个显式的"当前状态"读取语言,调用方(设置页)
     * 还需要另外调 AppCompatDelegate.setApplicationLocales() 驱动 Compose UI
     * 层的 stringResource(),两处真相要一起写,不能只改一处。 */
    suspend fun setLanguage(language: String) {
        context.dataStore.edit { it[Keys.LANGUAGE] = language }
        com.lodo.app.core.CurrentLang.value =
            if (language == "en") com.lodo.app.core.Lang.EN else com.lodo.app.core.Lang.ZH
    }

    suspend fun setNotificationPermissionDenied(denied: Boolean) {
        context.dataStore.edit { it[Keys.NOTIFICATION_PERMISSION_DENIED] = denied }
    }

    suspend fun setNotifyMissCount(count: Int) {
        context.dataStore.edit { it[Keys.NOTIFY_MISS_COUNT] = count }
    }

    /** 指定服务商的 key;DeepSeek 读不到新存储时回退旧字段。 */
    suspend fun apiKey(provider: String): String? {
        val p = context.dataStore.data.first()
        val stored = p[Keys.apiKeyFor(provider)]
            ?: (if (provider == "DeepSeek") p[Keys.API_KEY_ENCRYPTED] else null)
        return stored?.let { KeystoreCipher.decrypt(it) }
    }

    /** 当前选中服务商的 key(原有调用点继续可用)。 */
    suspend fun apiKey(): String? = apiKey(snapshot().aiProvider)

    suspend fun saveApiKey(key: String, provider: String) {
        context.dataStore.edit { it[Keys.apiKeyFor(provider)] = KeystoreCipher.encrypt(key) }
    }

    /** 当前 AI 请求配置:服务商端点/模型/key/个性,一次取齐。 */
    suspend fun aiConfig(): AIConfig {
        val s = snapshot()
        val preset = aiProviderPresets.firstOrNull { it.name == s.aiProvider }
        val endpoint = if (s.aiProvider == "自定义") s.aiCustomEndpoint.trim()
        else preset?.endpoint ?: aiProviderPresets[0].endpoint
        val model = s.aiModel.trim().ifEmpty { preset?.model ?: aiProviderPresets[0].model }
        val persona = when (s.personaStyle) {
            "默认" -> null
            "自定义" -> s.personaCustom.trim().ifEmpty { null }
            else -> personaPresets.firstOrNull { it.first == s.personaStyle }?.second
        }
        return AIConfig(
            apiKey = apiKey(s.aiProvider),
            endpoint = endpoint,
            model = model,
            persona = persona,
            reasoningEffort = s.thinkingLevel.takeIf { it != "off" },
        )
    }

    /** 是否已配置 Tavily key;command() 据此决定要不要拼入联网搜索 skill。 */
    suspend fun webSearchConfigured(): Boolean = !apiKey(WebSearchClient.PROVIDER_NAME).isNullOrBlank()
}
