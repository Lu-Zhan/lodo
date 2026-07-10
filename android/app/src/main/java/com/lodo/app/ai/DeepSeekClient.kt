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

/** AI 总入口解析出的单个操作。 */
sealed interface AIAction {
    data class Create(val task: ParsedTask) : AIAction
    data class Update(val uuid: String, val task: ParsedTask) : AIAction
    data class Complete(val uuid: String) : AIAction
    data class Delete(val uuid: String) : AIAction
}

/** AI 总入口的返回:操作列表,或关键信息缺失时的反问(附候选补充)。 */
sealed interface AICommandResult {
    data class Actions(val actions: List<AIAction>) : AICommandResult
    data class Clarify(val question: String, val options: List<String>) : AICommandResult
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

    /**
     * AI 总入口:给定当前待办列表,把用户的一句话解析成一组操作
     * (新建/修改/完成/删除,可多条),或在关键信息缺失时反问。
     * prompt 与 iOS DeepSeekClient.command 逐字一致。
     */
    suspend fun command(
        apiKey: String?,
        text: String,
        tasks: List<Pair<String, ParsedTask>>,
    ): AICommandResult {
        val list = JSONArray()
        tasks.forEach { (uuid, task) -> list.put(taskJson(task).put("uuid", uuid)) }
        val system = "你是提醒事项应用 lodo 的智能入口。给定当前待办事项列表和用户的一句话," +
            "解析出要执行的操作列表,只返回 JSON,不要任何其他文字。\n\n" +
            "支持的操作(action):\n" +
            "- 新建:{\"action\": \"create\", ...事项字段}\n" +
            "- 修改:{\"action\": \"update\", \"uuid\": \"原样取自当前待办列表,不要自己生成\", ...事项字段}" +
            "(输出修改后的完整字段值,用户没有提到的字段一律保持原值)\n" +
            "- 完成:{\"action\": \"complete\", \"uuid\": \"原样取自当前待办列表\"}\n" +
            "- 删除:{\"action\": \"delete\", \"uuid\": \"原样取自当前待办列表\"}\n\n" +
            "判断规则:\n" +
            "- 一句话里包含多件事时返回多个操作,如\"明天上午开会,周五交报告\"→ 两条 create。\n" +
            "- 修改/完成/删除按标题语义匹配列表中的事项(\"开会完成了\"→ complete," +
            "\"把取快递删了\"→ delete);匹配不到时返回 {\"error\": \"原因\"}。\n" +
            "- 新建缺少关键时间信息且无法按常理推断时(如只说\"提醒我交材料\"),不要猜," +
            "改为反问:{\"question\": \"要问用户的问题\", \"options\": [\"候选补充1\", \"候选补充2\", \"候选补充3\"]}," +
            "options 给 2-3 个具体可直接采用的补充(如\"明天 09:00\")。\n" +
            "- 无法解析时返回 {\"error\": \"原因\"}。\n\n" +
            "${timeContext()}\n\n当前待办列表:\n$list\n\n" +
            "返回格式(二选一):\n" +
            "{\"actions\": [操作, ...]}\n" +
            "{\"question\": \"...\", \"options\": [\"...\", \"...\"]}\n\n" +
            "事项字段:\n$taskSchema\n\n$taskRules"
        val payload = complete(apiKey, system, text)

        payload.optString("question").takeIf { it.isNotEmpty() }?.let { question ->
            val options = payload.optJSONArray("options")?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
            } ?: emptyList()
            return AICommandResult.Clarify(question, options)
        }
        val rawActions = payload.optJSONArray("actions")
            ?: throw DeepSeekException("无法解析:返回格式异常:缺少 actions")
        if (rawActions.length() == 0) throw DeepSeekException("无法解析:返回格式异常:缺少 actions")
        val actions = (0 until rawActions.length()).map { i ->
            val raw = rawActions.getJSONObject(i)
            fun validUuid(): String {
                val uuid = raw.optString("uuid")
                if (tasks.none { it.first == uuid }) {
                    throw DeepSeekException("无法解析:找不到要操作的事项")
                }
                return uuid
            }
            when (raw.optString("action")) {
                "create" -> AIAction.Create(parsePayload(raw))
                "update" -> AIAction.Update(validUuid(), parsePayload(raw))
                "complete" -> AIAction.Complete(validUuid())
                "delete" -> AIAction.Delete(validUuid())
                else -> throw DeepSeekException("无法解析:返回格式异常:未知 action")
            }
        }
        return AICommandResult.Actions(actions)
    }

    /** 按记忆文件为"没说时长"的新事项建议时长(分钟);无相近类型或明确不需要时返回 0。 */
    suspend fun suggestDuration(
        apiKey: String?, text: String, title: String, memory: String,
    ): Int {
        val system = "你是提醒事项应用 lodo 的时长建议助手。下面是\"事项类型 → 典型时长\"的记忆文件、" +
            "用户创建事项的原话和解析出的事项标题,只返回 JSON,不要任何其他文字。\n\n" +
            "判断规则:\n" +
            "- 用户原话明确表示不需要时长,或记忆中没有类型相近的条目 → {\"duration_minutes\": 0}\n" +
            "- 否则参考记忆中相近类型的典型时长 → {\"duration_minutes\": 分钟数}\n\n" +
            "记忆文件:\n$memory"
        return complete(apiKey, system, "原话:$text\n标题:$title").optInt("duration_minutes", 0)
    }

    /** 用一条新样本让模型归纳更新"事项类型 → 典型时长"记忆文件,返回新文件全文。 */
    suspend fun updateMemory(
        apiKey: String?, current: String?, title: String, durationMinutes: Int,
    ): String {
        val system = "你是提醒事项应用 lodo 的记忆管理助手,维护一份\"事项类型 → 典型时长\"的记忆文件。" +
            "给定现有记忆文件和一条新样本,输出更新后的完整记忆文件:按大致类型归纳," +
            "相近类型合并为一条,每条含典型时长(分钟)和 1-3 个例子,最多 15 条," +
            "markdown 列表格式,首行标题为\"# 事项时长记忆\"。" +
            "只返回 JSON:{\"memory\": \"更新后的文件全文\"},不要任何其他文字。\n\n" +
            "现有记忆文件:\n${current ?: "(空)"}"
        val memory = complete(apiKey, system, "新样本:$title,$durationMinutes 分钟").optString("memory")
        if (memory.isEmpty()) throw DeepSeekException("无法解析:返回格式异常:缺少 memory")
        return memory
    }

    /** 把今天的事项列表改写成一句话汇总,突出重点事件(每日汇总通知正文)。 */
    suspend fun summarizeToday(apiKey: String?, items: List<String>): String {
        val system = "你是提醒事项应用 lodo 的汇总助手。给定今天开始或到期的事项列表" +
            "(含时间与时长),用一句话概括今天的安排,突出重点事件" +
            "(如时间临近、耗时长或听起来重要的),不超过 40 个字," +
            "只返回 JSON:{\"summary\": \"一句话\"},不要任何其他文字。"
        val summary = complete(apiKey, system, JSONArray(items).toString()).optString("summary")
        if (summary.isBlank()) throw DeepSeekException("无法解析:返回格式异常:缺少 summary")
        return summary
    }

    /** 逾期事项的改期候选:2-3 个(口语化标签, 时间),时间必须晚于当前。 */
    suspend fun suggestReschedule(
        apiKey: String?,
        title: String,
        remindAt: LocalDateTime,
        durationMinutes: Int,
        isRecurring: Boolean,
    ): List<Pair<String, LocalDateTime>> {
        var info = "事项:$title\n原提醒时间:${remindAt.format(dateFormatter)}"
        if (durationMinutes > 0) info += ",时长 $durationMinutes 分钟"
        if (isRecurring) info += ",重复事项(只顺延本次)"
        val system = "你是提醒事项应用 lodo 的改期助手。一个事项已到期未完成,给出 2-3 个合理的" +
            "新提醒时间候选:按常理选时段(工作事项选工作时间,生活事项可选晚上或周末)," +
            "时间必须晚于当前时间。只返回 JSON,不要任何其他文字:\n" +
            "{\"candidates\": [{\"label\": \"口语化标签,如 今晚 20:00\", \"time\": \"YYYY-MM-DD HH:MM\"}, ...]}\n\n" +
            "${timeContext()}\n\n$info"
        val payload = complete(apiKey, system, "给出改期候选")
        val raw = payload.optJSONArray("candidates")
            ?: throw DeepSeekException("无法解析:返回格式异常:缺少 candidates")
        val now = LocalDateTime.now()
        val candidates = (0 until raw.length()).mapNotNull { i ->
            val item = raw.optJSONObject(i) ?: return@mapNotNull null
            val label = item.optString("label").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val date = try {
                LocalDateTime.parse(item.optString("time"), dateFormatter)
            } catch (_: DateTimeParseException) {
                return@mapNotNull null
            }
            if (date.isAfter(now)) label to date else null
        }
        if (candidates.isEmpty()) throw DeepSeekException("无法解析:没有可用的改期候选")
        return candidates
    }

    /** 每周完成洞察:把本地统计说成一句正向鼓励的话(不打分、不指责)。 */
    suspend fun weeklyInsight(apiKey: String?, stats: String): String {
        val system = "你是提醒事项应用 lodo 的回顾助手。根据一周完成统计,输出一句不超过 60 个字的" +
            "正向洞察:语气鼓励,肯定进步,并给一个具体可行的小建议;禁止任何指责性表述," +
            "禁止出现\"拖延\"\"失败\"等词。只返回 JSON:{\"insight\": \"一句话\"},不要任何其他文字。"
        val insight = complete(apiKey, system, stats).optString("insight")
        if (insight.isBlank()) throw DeepSeekException("无法解析:返回格式异常:缺少 insight")
        return insight
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
