package com.lodo.app.ai

import com.lodo.app.core.RepeatType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.concurrent.TimeUnit

/** AI 解析/编辑得到的事项字段,创建与编辑表单共用的值包。 */
data class ParsedTask(
    val title: String,
    val remindAt: LocalDateTime,
    val allDay: Boolean,
    val durationMinutes: Int,
    val repeatType: RepeatType,
    val repeatDays: List<Int>,
    val repeatTimes: List<String>,
)

/** 错误文案与 iOS DeepSeekError 一致,直接展示给用户。 */
class DeepSeekException(message: String) : Exception(message)

/** AI 总入口的路由结果:新建事项,或修改列表中的某个现有事项。 */
sealed interface AICommand {
    data class Create(val task: ParsedTask) : AICommand
    data class Update(val uuid: String, val task: ParsedTask) : AICommand
}

/** DeepSeek 自然语言创建/编辑,prompt 与 ios/Lodo/AI/DeepSeekClient.swift、web/lodo/ai.py 保持一致。 */
object DeepSeekClient {
    private const val ENDPOINT = "https://api.deepseek.com/chat/completions"
    private const val MODEL = "deepseek-chat"

    private val client = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val dateFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    private val hhmmRegex = Regex("""\d{1,2}:\d{2}""")

    private val taskSchema = """
        {"title": "事项内容(去掉时间词,保留做什么)",
          "remind_at": "YYYY-MM-DD HH:MM",
          "all_day": false,
          "duration_minutes": 0,
          "repeat_type": "none",
          "repeat_days": [],
          "repeat_times": []}
    """.trimIndent()

    private val taskRules = """
        规则:
        - "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
        - 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
        - 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
        - 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,remind_at 用 "YYYY-MM-DD 00:00"。
        - 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,可以有多个(如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
        - 无法解析出时间时,返回 {"error": "原因"}。
    """.trimIndent()

    private val formatAndRules = "返回格式(不适用的字段用默认值):\n$taskSchema\n\n$taskRules"

    private fun timeContext(): String {
        val now = LocalDateTime.now()
        val weekdays = "一二三四五六日"
        return "当前时间:${now.format(dateFormatter)}(星期${weekdays[now.dayOfWeek.value - 1]})"
    }

    /** 自然语言 → 新事项字段。 */
    suspend fun parse(apiKey: String?, text: String): ParsedTask {
        val system = "你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项," +
            "你需要解析出结构化信息,只返回 JSON,不要任何其他文字。\n\n" +
            "${timeContext()}\n\n$formatAndRules"
        return parsePayload(complete(apiKey, system, text))
    }

    /** 按自然语言指令修改现有事项;未提到的字段保持原值。 */
    suspend fun edit(apiKey: String?, current: ParsedTask, instruction: String): ParsedTask {
        val system = "你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令," +
            "输出修改后的完整事项,只返回 JSON,不要任何其他文字。" +
            "用户没有提到的字段一律保持原值;无法理解指令时返回 {\"error\": \"原因\"}。\n\n" +
            "${timeContext()}\n\n现有事项:\n${taskJson(current)}\n\n$formatAndRules"
        return parsePayload(complete(apiKey, system, instruction))
    }

    /** AI 总入口:给定当前待办列表,判断用户想新建事项还是修改某个现有事项。 */
    suspend fun command(
        apiKey: String?,
        text: String,
        tasks: List<Pair<String, ParsedTask>>,
    ): AICommand {
        val list = JSONArray()
        tasks.forEach { (uuid, task) -> list.put(taskJson(task).put("uuid", uuid)) }
        val system = "你是提醒事项应用 lodo 的智能入口。给定当前待办事项列表和用户的一句话," +
            "判断用户是想【新建】一个事项,还是【修改】列表中的某个现有事项," +
            "只返回 JSON,不要任何其他文字。\n\n" +
            "判断规则:\n" +
            "- 用户在描述一件新的事情 → 按\"新建\"格式返回。\n" +
            "- 用户提到了列表中已有的事项并要求调整(按标题语义匹配,如\"把开会改到晚上8点\")→ " +
            "按\"修改\"格式返回,输出修改后的完整字段值,用户没有提到的字段一律保持原值。\n" +
            "- 要修改但匹配不到事项、或无法判断/无法解析时,返回 {\"error\": \"原因\"}。\n\n" +
            "${timeContext()}\n\n当前待办列表:\n$list\n\n" +
            "返回格式(二选一,必须包含 \"action\" 字段;事项字段不适用的用默认值):\n" +
            "新建:{\"action\": \"create\", ...事项字段}\n" +
            "修改:{\"action\": \"update\", \"uuid\": \"原样取自当前待办列表,不要自己生成\", ...事项字段}\n\n" +
            "事项字段:\n$taskSchema\n\n$taskRules"
        val payload = complete(apiKey, system, text)
        val task = parsePayload(payload)
        return when (payload.optString("action")) {
            "create" -> AICommand.Create(task)
            "update" -> {
                val uuid = payload.optString("uuid")
                if (tasks.none { it.first == uuid }) {
                    throw DeepSeekException("无法解析:找不到要修改的事项")
                }
                AICommand.Update(uuid, task)
            }
            else -> throw DeepSeekException("无法解析:返回格式异常:缺少 action")
        }
    }

    private fun taskJson(task: ParsedTask): JSONObject = JSONObject()
        .put("title", task.title)
        .put("remind_at", task.remindAt.format(dateFormatter))
        .put("all_day", task.allDay)
        .put("duration_minutes", task.durationMinutes)
        .put("repeat_type", task.repeatType.raw)
        .put("repeat_days", JSONArray(task.repeatDays))
        .put("repeat_times", JSONArray(task.repeatTimes))

    /** 发起请求并取回模型返回的 JSON payload(含 error 检查)。 */
    private suspend fun complete(apiKey: String?, system: String, user: String): JSONObject =
        withContext(Dispatchers.IO) {
            if (apiKey.isNullOrBlank()) {
                throw DeepSeekException("未配置 DeepSeek API key,请到「设置」里填写。")
            }
            val body = JSONObject()
                .put("model", MODEL)
                .put(
                    "messages",
                    JSONArray()
                        .put(JSONObject().put("role", "system").put("content", system))
                        .put(JSONObject().put("role", "user").put("content", user))
                )
                .put("response_format", JSONObject().put("type", "json_object"))
                .put("temperature", 0)
            val request = Request.Builder()
                .url(ENDPOINT)
                .header("Authorization", "Bearer $apiKey")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = try {
                client.newCall(request).execute()
            } catch (e: IOException) {
                throw DeepSeekException("调用 DeepSeek 失败:${e.message}")
            }
            response.use { resp ->
                val text = resp.body?.string().orEmpty()
                if (resp.code != 200) {
                    throw DeepSeekException("调用 DeepSeek 失败:HTTP ${resp.code} ${text.take(200)}")
                }
                val payload = try {
                    val content = JSONObject(text)
                        .getJSONArray("choices").getJSONObject(0)
                        .getJSONObject("message").getString("content")
                    JSONObject(content)
                } catch (_: Exception) {
                    throw DeepSeekException("无法解析:返回格式异常")
                }
                payload.optString("error").takeIf { it.isNotEmpty() }?.let {
                    throw DeepSeekException("无法解析:$it")
                }
                payload
            }
        }

    /** 从 payload 里解析并校验事项字段。 */
    private fun parsePayload(payload: JSONObject): ParsedTask {
        val title = payload.optString("title").trim()
        val remindAt = try {
            LocalDateTime.parse(payload.optString("remind_at"), dateFormatter)
        } catch (_: DateTimeParseException) {
            null
        }
        if (title.isEmpty() || remindAt == null) {
            throw DeepSeekException("无法解析:返回格式异常:$payload")
        }
        val times = payload.optJSONArray("repeat_times")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
        } ?: emptyList()
        times.firstOrNull { !hhmmRegex.matches(it) }?.let {
            throw DeepSeekException("无法解析:时间点格式异常:$it")
        }
        val days = payload.optJSONArray("repeat_days")?.let { arr ->
            (0 until arr.length()).map { arr.optInt(it) }
        } ?: emptyList()
        return ParsedTask(
            title = title,
            remindAt = remindAt,
            allDay = payload.optBoolean("all_day", false),
            durationMinutes = payload.optInt("duration_minutes", 0),
            repeatType = RepeatType.from(payload.optString("repeat_type", "none")),
            repeatDays = days,
            repeatTimes = times,
        )
    }
}
