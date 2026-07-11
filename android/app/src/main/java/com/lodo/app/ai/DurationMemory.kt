package com.lodo.app.ai

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/**
 * AI 时长记忆:类 skill 的 markdown 文件("事项类型 → 典型时长"),对应 iOS DurationMemory。
 * 事项保存/完成(有时长)后交给 DeepSeek 归纳写回;失败静默,不影响主流程。
 * 另含"实际耗时"采样状态(智能 + 随机,时间稳定后不再问)。
 */
object DurationMemory {
    private const val THROTTLE_SECONDS = 60L
    private var lastLearnedAt: LocalDateTime = LocalDateTime.MIN
    private val stampFormatter = DateTimeFormatter.ISO_LOCAL_DATE_TIME

    private fun memoryFile(context: Context) = File(context.filesDir, "duration-memory.md")
    private fun samplesFile(context: Context) = File(context.filesDir, "duration-samples.json")

    /** 当前记忆文件内容;不存在或为空返回 null。 */
    fun content(context: Context): String? =
        memoryFile(context).takeIf { it.exists() }?.readText()?.takeIf { it.isNotBlank() }

    /** 手动保存编辑后的记忆内容(设置页编辑用);空内容等同重置。 */
    fun save(context: Context, text: String) {
        if (text.isBlank()) {
            reset(context)
        } else {
            memoryFile(context).writeText(text)
        }
    }

    /** 清空记忆。 */
    fun reset(context: Context) {
        memoryFile(context).delete()
    }

    /**
     * 用一条新样本(标题 + 时长)让 AI 归纳更新记忆文件。
     * force 绕过节流(实际耗时回答紧跟完成时的常规 learn,不该被节流吞掉)。
     */
    suspend fun learn(
        context: Context, config: AIConfig, title: String, durationMinutes: Int,
        force: Boolean = false,
    ) {
        if (durationMinutes <= 0 || config.apiKey.isNullOrBlank()) return
        val now = LocalDateTime.now()
        if (!force && java.time.Duration.between(lastLearnedAt, now).seconds < THROTTLE_SECONDS) return
        lastLearnedAt = now
        try {
            val updated = DeepSeekClient.updateMemory(config, content(context), title, durationMinutes)
            if (updated.isNotBlank()) memoryFile(context).writeText(updated)
        } catch (_: Exception) {
            // 尽力而为:断网/解析失败不影响主流程
        }
    }

    // ---- 实际耗时采样 ----

    private fun loadSamples(context: Context): JSONObject =
        try {
            JSONObject(samplesFile(context).takeIf { it.exists() }?.readText() ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }

    private fun saveSamples(context: Context, root: JSONObject) {
        try {
            samplesFile(context).writeText(root.toString())
        } catch (_: Exception) {
        }
    }

    /**
     * 这次完成要不要问实际耗时:计划>0、该事项未稳定、今天没问过任何事项、
     * 该事项 7 天内没问过,满足后再掷 50% 随机。返回 true 即视为"已问"(跳过也算)。
     */
    fun shouldAskActual(context: Context, title: String, planned: Int): Boolean {
        if (planned <= 0) return false
        val root = loadSamples(context)
        val sample = root.optJSONObject("samples")?.optJSONObject(title) ?: JSONObject()
        if (sample.optBoolean("stable")) return false
        if (root.optString("lastAskDay") == LocalDate.now().toString()) return false
        val lastAsked = try {
            LocalDateTime.parse(sample.optString("lastAsked"), stampFormatter)
        } catch (_: Exception) {
            LocalDateTime.MIN
        }
        if (java.time.Duration.between(lastAsked, LocalDateTime.now()).toDays() < 7) return false
        if (!listOf(true, false).random()) return false
        sample.put("lastAsked", LocalDateTime.now().format(stampFormatter))
        val samples = root.optJSONObject("samples") ?: JSONObject().also { root.put("samples", it) }
        samples.put(title, sample)
        root.put("lastAskDay", LocalDate.now().toString())
        saveSamples(context, root)
        return true
    }

    /**
     * 记录用户回答的实际耗时:入样本 + 喂记忆;
     * 最近 3 次实际值都与计划偏差 ≤20% 则标记稳定,以后不再问。
     */
    suspend fun recordActual(
        context: Context, config: AIConfig, title: String, planned: Int, minutes: Int,
    ) {
        val root = loadSamples(context)
        val samples = root.optJSONObject("samples") ?: JSONObject().also { root.put("samples", it) }
        val sample = samples.optJSONObject(title) ?: JSONObject()
        val actuals = (sample.optJSONArray("actuals") ?: JSONArray()).let { arr ->
            ((0 until arr.length()).map { arr.optInt(it) } + minutes).takeLast(3)
        }
        sample.put("actuals", JSONArray(actuals))
        if (actuals.size >= 3 && planned > 0 &&
            actuals.all { kotlin.math.abs(it - planned) <= maxOf(5, planned / 5) }
        ) {
            sample.put("stable", true)
        }
        samples.put(title, sample)
        saveSamples(context, root)
        learn(context, config, title, minutes, force = true)
    }
}
