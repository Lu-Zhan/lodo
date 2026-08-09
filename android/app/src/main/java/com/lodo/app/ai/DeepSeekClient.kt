package com.lodo.app.ai

import com.lodo.app.core.CurrentLang
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Strings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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

/** [DeepSeekClient.memorize] 整理出的字段;与 iOS MemorizedEntry 对齐,不含
 * 资产子功能字段(iOS 独有)。 */
data class MemorizedEntry(val title: String, val summary: String, val tags: List<String>)

/** [DeepSeekClient.askMemory] 的候选条目输入,与 iOS retrieveMemoryCandidates
 * 拼给 AI 的形状对齐;excerpt 是关键词匹配到的正文片段或摘要兜底。 */
data class MemoryCandidate(
    val uuid: String, val title: String, val summary: String,
    val tags: List<String>, val excerpt: String,
)

/** 一次 AI 请求所需的服务配置(服务商端点/模型/key/个性),由 SettingsRepository.aiConfig() 提供。 */
data class AIConfig(
    val apiKey: String?,
    val endpoint: String,
    val model: String,
    /** AI 个性描述;null 为无个性。 */
    val persona: String? = null,
    /** 思考强度:null/"off" = 不传;否则作为 reasoning_effort 传给支持推理的
     * 服务商/模型(OpenAI 兼容接口的通用字段名),不支持的会忽略这个参数。 */
    val reasoningEffort: String? = null,
)

/** AI 总入口解析出的单个操作。answer 仅在 command(webSearchEnabled = true) 时会出现
 * (配置了 Tavily key 才开启,和 iOS 同一个思路)。 */
sealed interface AIAction {
    data class Create(val task: ParsedTask) : AIAction
    data class Update(val uuid: String, val task: ParsedTask) : AIAction
    data class Complete(val uuid: String) : AIAction
    data class Delete(val uuid: String) : AIAction
    /** 与待办都无关的一般性问题,直接给用户的回答(可能是联网搜索后给出的)。 */
    data class Answer(val text: String) : AIAction
    /** 收藏一段内容原文,与 iOS AIAction.memorize 对齐。 */
    data class Memorize(val text: String) : AIAction
    /** 查询以前收藏/完成过的内容,与 iOS AIAction.askMemory 对齐。 */
    data class AskMemory(val question: String) : AIAction
    /** AI 主动建议收藏(不落库,UI 上一个"收藏这条"按钮点了才存),与 iOS
     * AIAction.suggestMemorize 对齐。 */
    data class SuggestMemorize(val text: String) : AIAction
}

/** ReAct 循环里可调用的只读工具;只读是硬性要求——写操作永远只能是最终答案的
 * 一部分,不能在推理过程中未经确认就被模型自己调用。 */
sealed interface AITool {
    data class WebSearch(val query: String) : AITool
    /** 用户直接给了一个链接、需要看链接内容本身(而不是搜关键词)时用;
     * 与 WebSearch 共用 webSearchEnabled 开关与 skill 文案。 */
    data class WebFetch(val url: String) : AITool
    /** 新建/修改待办要用到的内容依赖以前存的记忆,但还不知道具体写了什么时
     * 先查一次,与 iOS AITool.searchMemory 对齐。 */
    data class SearchMemory(val query: String) : AITool
}

/** AI 总入口的返回:操作列表、关键信息缺失时的反问(附候选补充),或 ReAct
 * 循环里的中间步骤(还没准备好给最终答案,先要执行一个只读工具)。 */
sealed interface AICommandResult {
    data class Actions(val actions: List<AIAction>) : AICommandResult
    data class Clarify(val question: String, val options: List<String>) : AICommandResult
    data class ToolCall(val thought: String, val tool: AITool) : AICommandResult
}

/** DeepSeek 自然语言创建/编辑,prompt 与 ios/Lodo/AI/DeepSeekClient.swift、web/lodo/ai.py 保持一致。 */
object DeepSeekClient {

    private val client = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val dateFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

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

    /** 联网搜索 skill,概念与 iOS AgentSkillStore 的 webSearch skill 一致(Android
     * 没有记忆功能,规则里去掉了"收藏/查记忆"相关的措辞);仅 webSearchEnabled
     * (配置了 Tavily key)时拼进 command() 的 system prompt。 */
    private val webSearchSkill = """
        额外支持的操作:
        - 直接回答:{"action": "answer", "text": "给用户的完整回答"}(用户的问题是一般性提问/最新信息查询,不是要新建/修改待办时用;可以是你已经确定知道答案、不需要查的情况,也可以是联网搜索后给出的)

        额外支持的工具:
        - 联网搜索:{"thought": "为什么需要搜", "tool": "web_search", "query": "要搜索的关键词"}(仅在需要查最新/实时/你不确定的信息时用;每次交流最多用一次,拿到搜索结果后必须在下一轮给出真正的最终答案——action 列表或反问,不能连续再搜、也不能一直用这个占位不给结果)
        - 抓取链接内容:{"thought": "为什么需要看这个链接", "tool": "web_fetch", "url": "用户给的链接原样"}(用户直接给了一个具体链接、要你总结/回答链接里的内容时用,直接抓取该链接本身,不要把链接当关键词去 web_search;同样每次交流最多用一次,拿到页面内容后必须在下一轮给出真正的最终答案)

        额外判断规则:
        - 用户提出一般性问题(如"今天天气怎么样""XX最新价格""这个词是什么意思")且和新建/修改待办都无关 → answer,此时整个 actions 只放这一条,不与其他操作混用(如果一句话里同时有新建待办和提问,只处理新建待办,提问可以重新单独问)。
        - 涉及待办本身的问题(如"我明天有什么安排""这个事项还有多久到期")按当前待办列表自己回答,不需要联网搜索。
        - 用户消息里包含具体链接(http/https 开头)且意图是了解/总结该链接内容时,用 web_fetch 直接抓取那个链接,不要用 web_search 搜链接文字本身。
        - 需要最新/实时信息(新闻、天气、价格、赛事结果等)但没有具体链接、或你不确定答案是否过时时,用 web_search 查关键词,不要凭空编内容;已经拿到搜索/抓取结果的,直接用结果内容给最终答案,不要重复搜/重复抓。
    """.trimIndent()

    /** 记忆 skill,与 iOS AgentSkillStore.defaultMemory 逐字一致(资产/人脉子功能
     * 目前仅 iOS 有,这份文案本身没提到它们,不需要额外裁剪)。仅 memoryEnabled
     * (记忆数据层已接入)时拼进 command() 的 system prompt。 */
    private val memorySkill = """
        额外支持的操作:
        - 收藏:{"action": "memorize", "text": "要收藏的内容原文"}
        - 查记忆:{"action": "ask_memory", "question": "用户想查询收藏的问题"}
        - 主动建议收藏(不是用户直接要求,是你判断这条信息以后可能有用):{"action": "suggest_memorize", "text": "建议收藏的内容,客观简洁"}
        - 先查记忆再回答:{"thought": "为什么需要先查", "tool": "search_memory", "query": "要查的内容"}(只在新建/修改事项要填的具体内容来自以前存的记忆、但你还不知道那段内容具体是什么时用;每次交流最多用一次,拿到查询结果后必须在下一轮给出真正的最终答案——action 列表或反问,不能连续再查、也不能一直用这个占位不给结果)

        额外判断规则:
        - 用户明确要求"记住/收藏/存一下"一段内容本身(而不是要提醒做某事)→ memorize,text 原样保留内容部分,只去掉"帮我记住"这类指令词,不要改写、不要总结;可与其他操作并存(如"明天9点开会,再记住门禁码1234"→ 一条 create + 一条 memorize)。
        - "记得提醒我…""帮我记住明天要交报告"这类带时间、语义是提醒做某事的,仍按 create 处理,不算收藏。
        - 用户没有要求收藏,但这句话*唯一*的意图是陈述一条看起来长期有效的偏好/习惯/事实(如"我周三下午一般没空""我对海鲜过敏")→ suggest_memorize,此时整个 actions 只放这一条,不与其他操作混用;大多数对话不需要这条,只在信息明显值得长期记住时才提,不要每句话都建议。用户当次消息如果同时有别的待办/新建/查询意图,只处理那些,不要附带这条建议。
        - 用户在询问以前收藏/记过的内容(如"我之前存的 wifi 密码是多少""收藏里有没有关于爬山的")→ ask_memory,此时整个 actions 只放这一条,不与其他操作混用;询问待办安排(如"我明天有什么事")不算查记忆。
        - 用户要新建/修改的事项,内容细节依赖以前存的记忆(如"参考我存的装备清单新建一个待办")且你还没看到那段记忆具体写了什么 → 先用 search_memory 查,不要凭空编内容;已经在对话历史里看到查询结果的,直接用结果里的内容给最终答案,不要重复查。
    """.trimIndent()

    /** AI 个性块:只影响面向用户的文字(反问/汇总/洞察),不影响 JSON 结构。 */
    private fun personaBlock(config: AIConfig): String =
        config.persona?.let { "\n\n说话风格(仅影响面向用户的文字,不得改变 JSON 结构与字段值):$it" } ?: ""

    private fun timeContext(): String {
        val now = LocalDateTime.now()
        val weekdays = "一二三四五六日"
        return "当前时间:${now.format(dateFormatter)}(星期${weekdays[now.dayOfWeek.value - 1]})"
    }

    /** 自然语言 → 新事项字段。 */
    suspend fun parse(config: AIConfig, text: String): ParsedTask {
        val system = "你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项," +
            "你需要解析出结构化信息,只返回 JSON,不要任何其他文字。\n\n" +
            "${timeContext()}\n\n$formatAndRules"
        return parsePayload(complete(config, system, text))
    }

    /** 按自然语言指令修改现有事项;未提到的字段保持原值。 */
    suspend fun edit(config: AIConfig, current: ParsedTask, instruction: String): ParsedTask {
        val system = "你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令," +
            "输出修改后的完整事项,只返回 JSON,不要任何其他文字。" +
            "用户没有提到的字段一律保持原值;无法理解指令时返回 {\"error\": \"原因\"}。\n\n" +
            "${timeContext()}\n\n现有事项:\n${taskJson(current)}\n\n$formatAndRules"
        return parsePayload(complete(config, system, instruction))
    }

    /**
     * AI 总入口:给定当前待办列表,把用户的一句话解析成一组操作
     * (新建/修改/完成/删除,可多条),或在关键信息缺失时反问。
     * prompt 与 iOS DeepSeekClient.command 逐字一致(webSearchEnabled 开启时
     * 额外拼入联网搜索 skill,和 iOS 的拼接顺序一致)。这是"AI 助手"对话入口,
     * 按设置里的思考强度传 reasoning_effort(thinking = true),不影响解析/
     * 汇总等其他后台小请求的响应速度。
     */
    suspend fun command(
        config: AIConfig,
        text: String,
        allTasks: List<Pair<String, ParsedTask>>,
        webSearchEnabled: Boolean = false,
        memoryEnabled: Boolean = false,
    ): AICommandResult {
        // token 预算:按提醒时间取最近 50 条进 prompt
        val tasks = allTasks.sortedBy { it.second.remindAt }.take(50)
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
            "事项字段:\n$taskSchema\n\n$taskRules" +
            (if (webSearchEnabled) "\n\n$webSearchSkill" else "") +
            (if (memoryEnabled) "\n\n$memorySkill" else "") + personaBlock(config)
        val payload = complete(config, system, text, thinking = true)
        return parseCommandResult(payload, tasks.map { it.first }.toSet(), webSearchEnabled, memoryEnabled)
    }

    /** 从 payload 里解析总入口结果(单测入口)。webSearchEnabled/memoryEnabled ==
     * false 时对应的工具/action 按未知工具/action 处理(即使模型幻觉出来,也保持
     * 旧行为——prompt 里根本没提过,幻觉概率很低)。 */
    internal fun parseCommandResult(
        payload: JSONObject, validUuids: Set<String>, webSearchEnabled: Boolean,
        memoryEnabled: Boolean = false,
    ): AICommandResult {
        payload.optString("question").takeIf { it.isNotEmpty() }?.let { question ->
            val options = payload.optJSONArray("options")?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
            } ?: emptyList()
            return AICommandResult.Clarify(question, options)
        }
        // ReAct 中间步骤:webSearchEnabled == false 时 prompt 里根本没提过这个
        // 选项,模型幻觉出来也不认——落到下面 actions 解析,大概率报"缺少 actions"。
        if (webSearchEnabled) {
            payload.optString("tool").takeIf { it == "web_search" }?.let {
                val thought = payload.optString("thought")
                val query = payload.optString("query")
                if (query.isBlank()) {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:web_search 缺少 query", CurrentLang.value))
                }
                return AICommandResult.ToolCall(thought, AITool.WebSearch(query))
            }
            payload.optString("tool").takeIf { it == "web_fetch" }?.let {
                val thought = payload.optString("thought")
                val url = payload.optString("url")
                if (url.isBlank()) {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:web_fetch 缺少 url", CurrentLang.value))
                }
                return AICommandResult.ToolCall(thought, AITool.WebFetch(url))
            }
        }
        if (memoryEnabled) {
            payload.optString("tool").takeIf { it == "search_memory" }?.let {
                val thought = payload.optString("thought")
                val query = payload.optString("query")
                if (query.isBlank()) {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:search_memory 缺少 query", CurrentLang.value))
                }
                return AICommandResult.ToolCall(thought, AITool.SearchMemory(query))
            }
        }
        val rawActions = payload.optJSONArray("actions")
            ?: throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 actions", CurrentLang.value))
        if (rawActions.length() == 0) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 actions", CurrentLang.value))
        val actions = (0 until rawActions.length()).map { i ->
            val raw = rawActions.getJSONObject(i)
            fun validUuid(): String {
                val uuid = raw.optString("uuid")
                if (uuid !in validUuids) {
                    throw DeepSeekException(Strings.translate("无法解析:找不到要操作的事项", CurrentLang.value))
                }
                return uuid
            }
            when (val action = raw.optString("action")) {
                "create" -> AIAction.Create(parsePayload(raw))
                "update" -> AIAction.Update(validUuid(), parsePayload(raw))
                "complete" -> AIAction.Complete(validUuid())
                "delete" -> AIAction.Delete(validUuid())
                "answer" -> if (webSearchEnabled) {
                    val text2 = raw.optString("text").trim()
                    if (text2.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:回答内容为空", CurrentLang.value))
                    AIAction.Answer(text2)
                } else {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value))
                }
                "memorize" -> if (memoryEnabled) {
                    val text2 = raw.optString("text").trim()
                    if (text2.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:收藏内容为空", CurrentLang.value))
                    AIAction.Memorize(text2)
                } else {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value))
                }
                "suggest_memorize" -> if (memoryEnabled) {
                    val text2 = raw.optString("text").trim()
                    if (text2.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:建议收藏内容为空", CurrentLang.value))
                    AIAction.SuggestMemorize(text2)
                } else {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value))
                }
                "ask_memory" -> if (memoryEnabled) {
                    val question = raw.optString("question").trim()
                    if (question.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:查询问题为空", CurrentLang.value))
                    AIAction.AskMemory(question)
                } else {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value))
                }
                else -> throw DeepSeekException(
                    Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value) + " $action")
            }
        }
        // 归一化:prompt 已要求 answer/ask_memory/suggest_memorize 这类"陈述性"
        // 结果单独出现,这里是模型不守规矩时的确定性兜底——和写操作混合时丢弃、
        // 只留写操作(写操作是用户要落地的事不能丢,提问可以重新问);全是陈述性
        // 结果时只留第一条,与 iOS route() 的归一化规则一致。
        val informational = actions.filter {
            it is AIAction.Answer || it is AIAction.AskMemory || it is AIAction.SuggestMemorize
        }
        if (informational.isNotEmpty()) {
            return if (informational.size == actions.size) {
                AICommandResult.Actions(listOf(actions[0]))
            } else {
                AICommandResult.Actions(actions - informational.toSet())
            }
        }
        return AICommandResult.Actions(actions)
    }

    /** 按记忆文件为"没说时长"的新事项建议时长(分钟);无相近类型或明确不需要时返回 0。 */
    suspend fun suggestDuration(
        config: AIConfig, text: String, title: String, memory: String,
    ): Int {
        val system = "你是提醒事项应用 lodo 的时长建议助手。下面是\"事项类型 → 典型时长\"的记忆文件、" +
            "用户创建事项的原话和解析出的事项标题,只返回 JSON,不要任何其他文字。\n\n" +
            "判断规则:\n" +
            "- 用户原话明确表示不需要时长,或记忆中没有类型相近的条目 → {\"duration_minutes\": 0}\n" +
            "- 否则参考记忆中相近类型的典型时长 → {\"duration_minutes\": 分钟数}\n\n" +
            "记忆文件:\n$memory"
        return complete(config, system, "原话:$text\n标题:$title").optInt("duration_minutes", 0)
    }

    /** 用一条新样本让模型归纳更新"事项类型 → 典型时长"记忆文件,返回新文件全文。 */
    suspend fun updateMemory(
        config: AIConfig, current: String?, title: String, durationMinutes: Int,
    ): String {
        val system = "你是提醒事项应用 lodo 的记忆管理助手,维护一份\"事项类型 → 典型时长\"的记忆文件。" +
            "给定现有记忆文件和一条新样本,输出更新后的完整记忆文件:按大致类型归纳," +
            "相近类型合并为一条,每条含典型时长(分钟)和 1-3 个例子,最多 15 条," +
            "markdown 列表格式,首行标题为\"# 事项时长记忆\"。" +
            "只返回 JSON:{\"memory\": \"更新后的文件全文\"},不要任何其他文字。\n\n" +
            "现有记忆文件:\n${current ?: "(空)"}"
        val memory = complete(config, system, "新样本:$title,$durationMinutes 分钟", timeoutSeconds = 60).optString("memory")
        if (memory.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 memory", CurrentLang.value))
        return memory
    }

    /** 收藏整理:把用户收藏的一段原文整理成标题/摘要/标签。与 iOS
     * DeepSeekClient.memorize 同构,但只保留标题/摘要/标签这部分——资产
     * (asset_value/liability/interest_rate)是 iOS 独有的资产子功能字段,
     * Android 这一轮的记忆系统没有对应数据模型,prompt 里不问这部分,
     * 因此与 iOS 的完整版 prompt 不逐字相同(那部分指令对 Android 没有意义)。 */
    suspend fun memorize(
        config: AIConfig, text: String, kind: String, existingTags: List<String> = emptyList(),
    ): MemorizedEntry {
        val tagRule = if (existingTags.isNotEmpty()) {
            "\n- 已有标签:${existingTags.take(50).joinToString("、")}。" +
                "tags 优先从已有标签中选用语义相近的,都不合适时才创建新标签。"
        } else ""
        val system = "你是提醒事项应用 lodo 的收藏整理助手。用户收藏了一段内容" +
            "(可能是网页正文、纯文本,或只有文件名),把它整理成一条记忆条目,只返回 JSON,不要任何其他文字:\n" +
            "{\"title\": \"不超过 20 字的标题\", \"summary\": \"不超过 100 字的客观摘要\", \"tags\": [\"2-4 个中文标签\"]}\n\n" +
            "规则:\n" +
            "- 标题概括内容主旨,不要照抄第一句。\n" +
            "- 内容为空时,基于已有信息推断,summary 注明\"(信息有限,整理仅供参考)\"。\n" +
            "- 完全无法整理时返回 {\"error\": \"原因\"}。$tagRule\n\n" +
            "内容类型:$kind"
        val user = text.ifBlank { "(无内容)" }
        val payload = complete(config, system, user, timeoutSeconds = 60)
        payload.optString("error").takeIf { it.isNotEmpty() }?.let {
            throw DeepSeekException(Strings.translate("无法解析:", CurrentLang.value) + it)
        }
        val title = payload.optString("title").trim()
        if (title.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 title", CurrentLang.value))
        val summary = payload.optString("summary").trim()
        val tags = payload.optJSONArray("tags")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
        } ?: emptyList()
        return MemorizedEntry(title, summary, tags)
    }

    /** 收藏问答:根据收藏条目列表回答用户的问题,与 iOS DeepSeekClient.askMemory
     * 同构。 */
    suspend fun askMemory(
        config: AIConfig, question: String,
        items: List<MemoryCandidate>,
    ): Pair<String, List<String>> {
        val list = JSONArray()
        items.forEach { item ->
            list.put(
                JSONObject()
                    .put("uuid", item.uuid)
                    .put("title", item.title)
                    .put("summary", item.summary)
                    .put("tags", JSONArray(item.tags))
                    .put("excerpt", item.excerpt)
            )
        }
        val system = "你是提醒事项应用 lodo 的收藏问答助手。下面是用户收藏的记忆条目列表," +
            "根据它们回答用户的问题(搜索、询问、归纳整理都可以),只返回 JSON,不要任何其他文字:\n" +
            "{\"answer\": \"回答\", \"related_uuids\": [\"相关条目的 uuid,原样取自列表,不要自己生成\"]}\n\n" +
            "规则:\n" +
            "- 回答基于条目内容,不要编造条目里没有的信息;不超过 120 个字。\n" +
            "- 找不到相关条目时,answer 说明没有找到相关收藏,related_uuids 为空数组。\n\n" +
            "${timeContext()}\n\n记忆条目列表:\n$list" + personaBlock(config)
        val payload = complete(config, system, question, timeoutSeconds = 60)
        val answer = payload.optString("answer").trim()
        if (answer.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 answer", CurrentLang.value))
        val validUuids = items.map { it.uuid }.toSet()
        val relatedUuids = payload.optJSONArray("related_uuids")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
        }?.filter { it in validUuids } ?: emptyList()
        return answer to relatedUuids
    }

    /** 把今天的事项列表改写成一句话汇总,突出重点事件(每日汇总通知正文)。 */
    suspend fun summarizeToday(config: AIConfig, items: List<String>): String {
        val system = "你是提醒事项应用 lodo 的汇总助手。给定今天开始或到期的事项列表" +
            "(含时间与时长),用一句话给出今天怎么安排的建议——不是单纯罗列," +
            "要指出哪些优先处理、哪些可以往后放,具体可执行,不超过 40 个字," +
            "只返回 JSON:{\"summary\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        val summary = complete(config, system, JSONArray(items).toString(), timeoutSeconds = 60).optString("summary")
        if (summary.isBlank()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 summary", CurrentLang.value))
        return summary
    }

    /** 逾期事项的改期候选:2-3 个(口语化标签, 时间),时间必须晚于当前。 */
    suspend fun suggestReschedule(
        config: AIConfig,
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
        val payload = complete(config, system, "给出改期候选")
        val raw = payload.optJSONArray("candidates")
            ?: throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 candidates", CurrentLang.value))
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
        if (candidates.isEmpty()) throw DeepSeekException(Strings.translate("无法解析:没有可用的改期候选", CurrentLang.value))
        return candidates
    }

    /** 每周完成洞察:把本地统计说成一句正向鼓励的话(不打分、不指责)。 */
    suspend fun weeklyInsight(config: AIConfig, stats: String): String {
        val system = "你是提醒事项应用 lodo 的回顾助手。根据一周完成统计,输出一句不超过 60 个字的" +
            "正向洞察:语气鼓励,肯定进步,并给一个具体可行的小建议;禁止任何指责性表述," +
            "禁止出现\"拖延\"\"失败\"等词。只返回 JSON:{\"insight\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        val insight = complete(config, system, stats, timeoutSeconds = 60).optString("insight")
        if (insight.isBlank()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 insight", CurrentLang.value))
        return insight
    }

    /** 定时任务(AI 例行任务)到点执行:用户自己写的指令(如"总结今日待办""看
     * 天气给穿搭建议"),给出一句简短结果用于推送通知。与 iOS runRoutine 同构,
     * 但这一轮 Android 不做 ReAct/联网(iOS "允许 ReAct 联网"),只是单轮直接
     * 作答——指令依赖联网实时信息时模型会如实说明取决于自身知识范围,不会
     * 编造。 */
    suspend fun runRoutine(config: AIConfig, prompt: String): String {
        val system = "你是提醒事项应用 lodo 的定时任务执行助手。用户设置了一条到点自动执行的指令," +
            "现在到点了,请执行这条指令并给出结果,只返回 JSON,不要任何其他文字:\n" +
            "{\"result\": \"执行结果,不超过 100 字\"}\n\n${timeContext()}" + personaBlock(config)
        val result = complete(config, system, prompt, timeoutSeconds = 60).optString("result")
        if (result.isBlank()) throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 result", CurrentLang.value))
        return result
    }

    private fun taskJson(task: ParsedTask): JSONObject = JSONObject()
        .put("title", task.title)
        .put("remind_at", task.remindAt.format(dateFormatter))
        .put("all_day", task.allDay)
        .put("duration_minutes", task.durationMinutes)
        .put("repeat_type", task.repeatType.raw)
        .put("repeat_days", JSONArray(task.repeatDays))
        .put("repeat_times", JSONArray(task.repeatTimes))

    /**
     * 模型输出文本 → JSON:剥 markdown 围栏、从首个 { 截到末个 },
     * 兼容部分服务不严格遵守纯 JSON 的情况(与 iOS decodePayload 一致)。
     */
    private fun decodePayload(text: String): JSONObject {
        var cleaned = text.trim()
        if (cleaned.startsWith("```")) {
            cleaned = cleaned.replace("```json", "").replace("```", "").trim()
        }
        val start = cleaned.indexOf('{')
        val end = cleaned.lastIndexOf('}')
        if (start in 0 until end) cleaned = cleaned.substring(start, end + 1)
        return try {
            JSONObject(cleaned)
        } catch (_: Exception) {
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常", CurrentLang.value))
        }
    }

    /** 传输层错误(超时/连接问题)延时后重试一次;HTTP 状态码错误不重试
     * (同一个请求重试不会变好)。 */
    private suspend fun executeWithRetry(client: OkHttpClient, request: Request): okhttp3.Response {
        return try {
            client.newCall(request).execute()
        } catch (e: IOException) {
            delay(500)
            try {
                client.newCall(request).execute()
            } catch (e: IOException) {
                throw DeepSeekException(
                    Strings.translate("调用 DeepSeek 失败:", CurrentLang.value) + e.message)
            }
        }
    }

    /** 发起请求并取回模型返回的 JSON payload(含 error 检查)。
     * timeoutSeconds:交互型请求默认 20 秒;汇总/记忆等后台请求传 60 秒。
     * thinking:true 时按设置里的思考强度带上 reasoning_effort(仅 command() 传
     * true——AI 助手对话入口才需要深度推理,解析/汇总等后台小请求不需要多等)。 */
    private suspend fun complete(
        config: AIConfig, system: String, user: String, timeoutSeconds: Long = 20,
        thinking: Boolean = false,
    ): JSONObject =
        withContext(Dispatchers.IO) {
            if (config.apiKey.isNullOrBlank()) {
                throw DeepSeekException(Strings.translate("未配置 DeepSeek API key,请到「设置」里填写。", CurrentLang.value))
            }
            if (config.endpoint.isBlank()) {
                throw DeepSeekException(Strings.translate("调用 DeepSeek 失败:无效的服务地址,请到「设置」里检查 AI 服务商配置。", CurrentLang.value))
            }
            val body = JSONObject()
                .put("model", config.model)
                .put(
                    "messages",
                    JSONArray()
                        .put(JSONObject().put("role", "system").put("content", system))
                        .put(JSONObject().put("role", "user").put("content", user))
                )
                .put("response_format", JSONObject().put("type", "json_object"))
                .put("temperature", 0)
            // reasoning_effort:OpenAI 兼容接口里推理强度的通用字段名,支持推理的
            // 服务商/模型会据此调整思考深度,不支持的会直接忽略这个多余字段。
            if (thinking && !config.reasoningEffort.isNullOrBlank() && config.reasoningEffort != "off") {
                body.put("reasoning_effort", config.reasoningEffort)
            }
            val request = Request.Builder()
                .url(config.endpoint)
                .header("Authorization", "Bearer ${config.apiKey}")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val call = client.newBuilder()
                .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .callTimeout(timeoutSeconds + 5, TimeUnit.SECONDS)
                .build()
            val response = executeWithRetry(call, request)

            response.use { resp ->
                val text = resp.body?.string().orEmpty()
                if (resp.code != 200) {
                    throw DeepSeekException(
                        Strings.translate("调用 DeepSeek 失败:", CurrentLang.value) +
                            "HTTP ${resp.code} ${text.take(200)}")
                }
                val content = try {
                    JSONObject(text)
                        .getJSONArray("choices").getJSONObject(0)
                        .getJSONObject("message").getString("content")
                } catch (_: Exception) {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常", CurrentLang.value))
                }
                val payload = decodePayload(content)
                payload.optString("error").takeIf { it.isNotEmpty() }?.let {
                    throw DeepSeekException(Strings.translate("无法解析:", CurrentLang.value) + it)
                }
                payload
            }
        }

    /** 从 payload 里解析并校验事项字段;任何字段超出合理范围直接抛错(不做静默
     * clamp)——AI 返回离谱值通常本身就意味着误解了用户意图,静默改写会产生
     * "AI 说建的是 A,实际存的是被偷偷改过的 A'"这种不可见偏差,不如报错更安全。 */
    private fun parsePayload(payload: JSONObject): ParsedTask {
        val title = payload.optString("title").trim()
        val remindAt = try {
            LocalDateTime.parse(payload.optString("remind_at"), dateFormatter)
        } catch (_: DateTimeParseException) {
            null
        }
        if (title.isEmpty() || remindAt == null) {
            throw DeepSeekException(
                Strings.translate("无法解析:返回格式异常:", CurrentLang.value) + payload)
        }
        val times = payload.optJSONArray("repeat_times")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
        } ?: emptyList()
        times.firstOrNull { !isValidHhmm(it) }?.let {
            throw DeepSeekException(
                Strings.translate("无法解析:时间点格式异常:", CurrentLang.value) + it)
        }
        val duration = payload.optInt("duration_minutes", 0)
        if (duration !in 0..1440) {
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:时长超出范围", CurrentLang.value))
        }
        val rawDays = payload.optJSONArray("repeat_days")?.let { arr ->
            (0 until arr.length()).map { arr.optInt(it) }
        } ?: emptyList()
        if (rawDays.any { it !in 0..6 }) {
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:周几超出范围", CurrentLang.value))
        }
        val days = rawDays.toSortedSet().toList()
        return ParsedTask(
            title = title,
            remindAt = remindAt,
            allDay = payload.optBoolean("all_day", false),
            durationMinutes = duration,
            repeatType = RepeatType.from(payload.optString("repeat_type", "none")),
            repeatDays = days,
            repeatTimes = times,
        )
    }

    private fun isValidHhmm(value: String): Boolean {
        val parts = value.split(":")
        if (parts.size != 2) return false
        if (parts[0].length !in 1..2 || parts[1].length != 2) return false
        val h = parts[0].toIntOrNull() ?: return false
        val m = parts[1].toIntOrNull() ?: return false
        return h in 0..23 && m in 0..59
    }
}
