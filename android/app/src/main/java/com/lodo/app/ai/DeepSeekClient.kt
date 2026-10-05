package com.lodo.app.ai

import com.lodo.app.core.CurrentLang
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Strings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
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
    /** 所属项目/主题,空串 = 没有。 */
    val project: String = "",
)

/** 错误文案与 iOS DeepSeekError 一致,直接展示给用户。 */
open class DeepSeekException(message: String) : Exception(message)

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

/** AI 总入口解析出的单个操作。answer(直接回话)不受任何开关门控,聊天入口随时
 * 可能出现;联网搜索只决定它答之前能不能先查一下,和 iOS 同一个思路。 */
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
    /** AI 主动建议收藏(不落库,UI 上一个"收藏这条"按钮点了才存)。 */
    data class SuggestMemorize(val text: String) : AIAction
    /** 对话中顺带提到的重点事实,静默落库成「AI记录」(同 iOS auto_memorize)。 */
    data class AutoMemorize(val title: String, val text: String) : AIAction
    /** 用户的长期做事偏好,静默记进 agent-preferences.md(同 iOS remember_preference)。 */
    data class RememberPreference(val text: String) : AIAction
    data class PlanTrip(val plan: TripPlanProposal) : AIAction
    data class EditTrip(val edit: TripEdit) : AIAction
    data class Countdown(val op: CountdownOp) : AIAction
    data class Asset(val op: AssetOp) : AIAction
    data class Feed(val op: FeedOp) : AIAction
}

/** ReAct 循环里可调用的只读工具;只读是硬性要求——写操作永远只能是最终答案的
 * 一部分,不能在推理过程中未经确认就被模型自己调用。 */
sealed interface AITool {
    data class WebSearch(val query: String) : AITool
    /** 用户直接给了一个链接、需要看链接内容本身(而不是搜关键词)时用;
     * 与 WebSearch 共用 webSearchEnabled 开关与 skill 文案。 */
    data class WebFetch(val url: String) : AITool
    data class SearchMemory(val query: String) : AITool
    data class ReadHealth(val days: Int) : AITool
    data class ReadTrip(val name: String) : AITool
    data class SearchNews(val query: String) : AITool
    /** 取一条已启用外部 skill 的正文(只读,计入 3 轮上限);定时任务那条路径不给。 */
    data class LoadSkill(val name: String) : AITool
}

/** AI 总入口的返回:操作列表、关键信息缺失时的提问卡,或 ReAct 循环里的中间步骤。
 * Android 原来的单问题 clarify 已升级成 iOS 的多问题 ask(CLAUDE.md 约定:要动就是
 * 把 Android 也升级成 ask);老格式 {"question", "options"} 解析时折算成一道题。 */
sealed interface AICommandResult {
    data class Actions(val actions: List<AIAction>) : AICommandResult
    data class Ask(val questions: List<AskQuestion>) : AICommandResult
    data class ToolCall(val thought: String, val tool: AITool) : AICommandResult
}

/** 调用方声明的能力(由数据/权限/配置决定),再与 skill 开关相与才生效(同 iOS CommandCapabilities)。 */
data class CommandCapabilities(
    val memory: Boolean = false,
    val webSearch: Boolean = false,
    val health: Boolean = false,
    val travel: Boolean = false,
    val tripPlan: Boolean = false,
    val news: Boolean = false,
    val countdown: Boolean = false,
    val assets: Boolean = false,
    val feeds: Boolean = false,
)

/** prompt 里倒数日/资产/订阅清单的一行(带 id,修改时原样引用)。 */
data class CountdownPromptEntry(
    val id: String, val title: String, val start: LocalDateTime, val end: LocalDateTime?, val allDay: Boolean,
    val showInWidget: Boolean, val archived: Boolean, val startReminders: List<Int>, val endReminders: List<Int>,
)
data class AssetPromptEntry(
    val id: String, val title: String, val category: String, val value: Double?, val currency: String,
    val liability: Double?, val interestRate: Double?, val updatedAt: LocalDateTime,
)
data class FeedPromptEntry(val id: String, val title: String, val url: String, val kind: String, val enabled: Boolean)

/** command 的上下文:能力 + 各清单 + 页面焦点 + 对话历史 + 摘要 + 偏好。 */
data class CommandContext(
    val tasks: List<Pair<String, ParsedTask>>,
    val caps: CommandCapabilities = CommandCapabilities(),
    val countdowns: List<CountdownPromptEntry> = emptyList(),
    val assets: List<AssetPromptEntry> = emptyList(),
    val feeds: List<FeedPromptEntry> = emptyList(),
    /** 页面焦点块(在哪一页唤出),null = 不出现。 */
    val pageFocus: String? = null,
    val history: List<Pair<String, String>> = emptyList(),
    val summary: String? = null,
    val preferences: String? = null,
    val existingProjects: List<String> = emptyList(),
)

/** 模型按约定返回 {"error": "原因"}——那是它想对用户说的话,command 入口当成 answer。 */
class ModelErrorException(message: String) : DeepSeekException(message)

/** DeepSeek 自然语言创建/编辑,prompt 与 ios/Lodo/AI/DeepSeekClient.swift、web/lodo/ai.py 保持一致。 */
object DeepSeekClient {

    private val client = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private val dateFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /** 新建/编辑共用的字段格式与规则 = todo skill(同 iOS parse/edit 用 todoContent)。 */
    private fun formatAndRules(projects: List<String> = emptyList()) =
        "返回格式(不适用的字段用默认值):\n" + AgentSkillStore.todoContent(projects)

    /** AI 个性块:只影响面向用户的文字(反问/汇总/洞察),不影响 JSON 结构。 */
    private fun personaBlock(config: AIConfig): String =
        config.persona?.let { "\n\n说话风格(仅影响面向用户的文字,不得改变 JSON 结构与字段值):$it" } ?: ""

    fun timeContext(): String {
        val now = LocalDateTime.now()
        val weekdays = "一二三四五六日"
        return "当前时间:${now.format(dateFormatter)}(星期${weekdays[now.dayOfWeek.value - 1]})"
    }

    /** 自然语言 → 新事项字段。 */
    suspend fun parse(config: AIConfig, text: String, projects: List<String> = emptyList()): ParsedTask {
        val system = "你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项," +
            "你需要解析出结构化信息,只返回 JSON,不要任何其他文字。\n\n" +
            "${timeContext()}\n\n${formatAndRules(projects)}"
        return parsePayload(complete(config, system, text))
    }

    /** 按自然语言指令修改现有事项;未提到的字段保持原值。 */
    suspend fun edit(config: AIConfig, current: ParsedTask, instruction: String): ParsedTask {
        val system = "你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令," +
            "输出修改后的完整事项,只返回 JSON,不要任何其他文字。" +
            "用户没有提到的字段一律保持原值;无法理解指令时返回 {\"error\": \"原因\"}。\n\n" +
            "${timeContext()}\n\n现有事项:\n${taskJson(current)}\n\n${formatAndRules()}"
        return parsePayload(complete(config, system, instruction))
    }

    /** 实际生效的能力 = 调用方能力 ∧ skill 开关;prompt 拼装和解析共用这一组值。 */
    fun effectiveCaps(caps: CommandCapabilities) = CommandCapabilities(
        memory = caps.memory && AgentSkillStore.isEnabled(AgentSkillId.MEMORY),
        webSearch = caps.webSearch && AgentSkillStore.isEnabled(AgentSkillId.WEB_SEARCH),
        health = caps.health && AgentSkillStore.isEnabled(AgentSkillId.HEALTH),
        travel = caps.travel && AgentSkillStore.isEnabled(AgentSkillId.TRAVEL),
        tripPlan = caps.tripPlan && AgentSkillStore.isEnabled(AgentSkillId.TRIP_PLANNER),
        news = caps.news && AgentSkillStore.isEnabled(AgentSkillId.NEWS),
        countdown = caps.countdown && AgentSkillStore.isEnabled(AgentSkillId.COUNTDOWN),
        assets = caps.assets && AgentSkillStore.isEnabled(AgentSkillId.ASSET_LEDGER),
        feeds = caps.feeds && AgentSkillStore.isEnabled(AgentSkillId.FEEDS),
    )

    private val dayOnly = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    private fun countdownList(entries: List<CountdownPromptEntry>): String = JSONArray().apply {
        entries.forEach { e ->
            val f = if (e.allDay) dayOnly else dateFormatter
            put(JSONObject().put("id", e.id).put("title", e.title).put("start", e.start.format(f))
                .put("all_day", e.allDay).put("show_in_widget", e.showInWidget).apply {
                    if (e.archived) put("archived", true)
                    e.end?.let { put("end", it.format(f)) }
                    if (e.startReminders.isNotEmpty()) put("start_reminders", JSONArray(e.startReminders))
                    if (e.endReminders.isNotEmpty()) put("end_reminders", JSONArray(e.endReminders))
                })
        }
    }.toString()

    private fun assetList(entries: List<AssetPromptEntry>): String = JSONArray().apply {
        entries.forEach { e ->
            put(JSONObject().put("id", e.id).put("title", e.title).put("category", e.category)
                .put("currency", e.currency).put("updated", e.updatedAt.format(dayOnly)).apply {
                    e.value?.let { put("value", it) }
                    e.liability?.let { put("liability", it) }
                    e.interestRate?.let { put("interest_rate", it) }
                })
        }
    }.toString()

    private fun feedList(entries: List<FeedPromptEntry>): String = JSONArray().apply {
        entries.forEach { e ->
            put(JSONObject().put("id", e.id).put("title", e.title).put("url", e.url).put("kind", e.kind)
                .apply { if (!e.enabled) put("enabled", false) })
        }
    }.toString()

    /** command 实际发给模型的 system prompt(设置里「查看最终 Prompt」与真实请求共用),
     * 拼接顺序同 iOS commandSystemPrompt。 */
    fun commandSystemPrompt(config: AIConfig, ctx: CommandContext): String {
        val caps = effectiveCaps(ctx.caps)
        val list = JSONArray()
        ctx.tasks.take(50).forEach { (uuid, task) -> list.put(taskJson(task).put("uuid", uuid)) }
        fun block(on: Boolean, id: AgentSkillId) = if (on) "\n\n" + AgentSkillStore.content(id) else ""
        val countdownBlock = if (caps.countdown) "\n\n" + AgentSkillStore.content(AgentSkillId.COUNTDOWN) +
            "\n\n当前倒数日列表:\n" + (if (ctx.countdowns.isEmpty()) "(还没有)" else countdownList(ctx.countdowns)) else ""
        val assetBlock = if (caps.assets) "\n\n" + AgentSkillStore.content(AgentSkillId.ASSET_LEDGER) +
            "\n\n当前资产列表:\n" + (if (ctx.assets.isEmpty()) "(还没有)" else assetList(ctx.assets)) else ""
        val feedBlock = if (caps.feeds) "\n\n" + AgentSkillStore.content(AgentSkillId.FEEDS) +
            "\n\n当前订阅列表:\n" + (if (ctx.feeds.isEmpty()) "(还没有)" else feedList(ctx.feeds)) else ""
        val preferences = ctx.preferences?.takeIf { it.isNotBlank() }?.let {
            "\n\n用户偏好(你以前记下的,除非这次用户明确另说,否则一律遵守):\n$it"
        } ?: ""
        val focus = ctx.pageFocus?.let { "\n\n$it" } ?: ""
        val summary = ctx.summary?.takeIf { it.isNotBlank() }?.let {
            "\n\n更早对话的摘要(更久以前聊过的,已经压缩过;对话历史里找不到的上下文从这里找):\n$it"
        } ?: ""
        val history = if (ctx.history.isEmpty()) "" else
            "\n\n对话历史(供理解上下文用,不要重复执行历史里已经完成的操作):\n" +
                ctx.history.joinToString("\n") { (role, content) -> (if (role == "user") "用户" else "助手") + ":" + content }
        return AgentSkillStore.content(AgentSkillId.AGENT) + "\n\n" +
            AgentSkillStore.todoContent(ctx.existingProjects) +
            block(caps.memory, AgentSkillId.MEMORY) + block(caps.webSearch, AgentSkillId.WEB_SEARCH) +
            block(caps.health, AgentSkillId.HEALTH) + block(caps.travel, AgentSkillId.TRAVEL) +
            block(caps.tripPlan, AgentSkillId.TRIP_PLANNER) + block(caps.news, AgentSkillId.NEWS) +
            countdownBlock + assetBlock + feedBlock +
            (AgentSkillStore.catalogBlock()?.let { "\n\n" + it } ?: "") +
            "\n\n" + timeContext() + preferences + focus +
            "\n\n当前待办列表:\n" + list + personaBlock(config) + summary + history
    }

    /**
     * AI 总入口:给定当前待办列表和上下文,把用户的一句话解析成操作,或在关键信息缺失时
     * 用提问卡反问。prompt 拼装同 iOS(总则 + 待办 + 按能力拼入的 skill + 清单 + 时间/偏好/
     * 页面焦点 + 待办列表 + 个性 + 摘要 + 历史)。这是"AI 助手"对话入口,按设置里的思考
     * 强度传 reasoning_effort。模型用 {"error": "原因"} 表示没有能执行的操作时,当成回话。
     */
    suspend fun command(
        config: AIConfig, text: String, ctx: CommandContext,
        /** 非 null 时走 SSE 流式,把 answer 正文边收边吐(全文,不是增量);同 iOS onStream。 */
        onStream: ((String) -> Unit)? = null,
        /** 推理模型先吐的思考过程,喂给「思考中…」那条提示。 */
        onReasoning: ((String) -> Unit)? = null,
    ): AICommandResult {
        val system = commandSystemPrompt(config, ctx)
        val caps = effectiveCaps(ctx.caps)
        val payload = try {
            if (onStream != null) completeStreaming(config, system, text, 90, thinking = true, onStream, onReasoning ?: {})
            else complete(config, system, text, timeoutSeconds = 90, thinking = true)
        } catch (e: ModelErrorException) {
            val message = e.message.orEmpty().removePrefix(Strings.translate("无法解析:", CurrentLang.value)).trim()
            if (message.isNotEmpty()) return AICommandResult.Actions(listOf(AIAction.Answer(message)))
            throw e
        }
        val result = parseCommandResult(
            payload, ctx.tasks.take(50).map { it.first }.toSet(), caps.webSearch, caps.memory,
            health = caps.health, travel = caps.travel, tripPlan = caps.tripPlan, news = caps.news,
            countdown = caps.countdown, validCountdownIds = ctx.countdowns.map { it.id },
            assets = caps.assets, validAssetIds = ctx.assets.map { it.id },
            feeds = caps.feeds, validFeedIds = ctx.feeds.map { it.id },
            loadSkill = AgentSkillStore.catalogBlock() != null,
        )
        return guardMisdirectedUpdates(result, ctx.tasks, text)
    }

    /** 防"张冠李戴"(同 iOS guardMisdirectedUpdates):一条 update 把标题换成了毫不相干的
     * 另一件事、用户这句话里又没提到原来那件事,改成新建,原事项不动。 */
    internal fun guardMisdirectedUpdates(
        result: AICommandResult, tasks: List<Pair<String, ParsedTask>>, userText: String,
    ): AICommandResult {
        if (result !is AICommandResult.Actions) return result
        val userGrams = bigrams(userText)
        return AICommandResult.Actions(result.actions.map { action ->
            if (action !is AIAction.Update) return@map action
            val original = tasks.firstOrNull { it.first == action.uuid }?.second ?: return@map action
            if (original.title == action.task.title) return@map action
            val old = bigrams(original.title)
            if (old.isEmpty() || old.any { it in bigrams(action.task.title) } || old.any { it in userGrams }) action
            else AIAction.Create(action.task)
        })
    }

    internal fun bigrams(text: String): Set<String> {
        val chars = text.lowercase().filter { it.isLetterOrDigit() }.map { it.toString() }
        if (chars.size <= 1) return chars.toSet()
        return (0 until chars.size - 1).map { chars[it] + chars[it + 1] }.toSet()
    }

    private fun parseToolCall(
        raw: JSONObject, name: String, webSearchEnabled: Boolean, memoryEnabled: Boolean,
        health: Boolean, travel: Boolean, news: Boolean, loadSkill: Boolean = false,
    ): AICommandResult.ToolCall? {
        val thought = raw.optString("thought")
        fun err(detail: String): Nothing =
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:$detail", CurrentLang.value))
        return when {
            name == "web_search" && webSearchEnabled -> {
                val query = raw.optString("query").trim()
                if (query.isBlank()) err("web_search 缺少 query")
                AICommandResult.ToolCall(thought, AITool.WebSearch(query))
            }
            name == "web_fetch" && webSearchEnabled -> {
                val url = raw.optString("url").trim()
                if (url.isBlank()) err("web_fetch 缺少 url")
                AICommandResult.ToolCall(thought, AITool.WebFetch(url))
            }
            name == "search_memory" && memoryEnabled -> {
                val query = raw.optString("query").trim()
                if (query.isBlank()) err("search_memory 缺少 query")
                AICommandResult.ToolCall(thought, AITool.SearchMemory(query))
            }
            name == "read_health" && health -> {
                val days = raw.optString("days").trim().toIntOrNull() ?: 7
                AICommandResult.ToolCall(thought, AITool.ReadHealth(days.coerceIn(1, 90)))
            }
            name == "read_trip" && travel -> AICommandResult.ToolCall(thought, AITool.ReadTrip(raw.optString("name").trim()))
            name == "search_news" && news -> AICommandResult.ToolCall(thought, AITool.SearchNews(raw.optString("query").trim()))
            name == "load_skill" && loadSkill -> {
                val skill = raw.optString("name").trim()
                if (skill.isBlank()) err("load_skill 缺少 name")
                AICommandResult.ToolCall(thought, AITool.LoadSkill(skill))
            }
            else -> null
        }
    }

    /** 从 payload 里解析总入口结果(单测入口)。各能力为 false 时对应的工具/action 按未知处理
     * (即使模型幻觉出来也不认),同 iOS parseCommand。 */
    internal fun parseCommandResult(
        payload: JSONObject, validUuids: Set<String>, webSearchEnabled: Boolean,
        memoryEnabled: Boolean = false,
        health: Boolean = false, travel: Boolean = false, tripPlan: Boolean = false, news: Boolean = false,
        countdown: Boolean = false, validCountdownIds: List<String> = emptyList(),
        assets: Boolean = false, validAssetIds: List<String> = emptyList(),
        feeds: Boolean = false, validFeedIds: List<String> = emptyList(),
        now: LocalDateTime = LocalDateTime.now(),
        /** 有已启用的外部 skill 时才认 load_skill(同 iOS loadSkillEnabled)。 */
        loadSkill: Boolean = false,
    ): AICommandResult {
        payload.optJSONArray("ask")?.takeIf { it.length() > 0 }?.let { return AICommandResult.Ask(parseAsk(it)) }
        // 老格式单问题反问:折算成一道题。
        payload.optString("question").takeIf { it.isNotEmpty() && !payload.has("actions") }?.let { question ->
            val options = payload.optJSONArray("options")?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.optString(it).takeIf(String::isNotEmpty) }
            } ?: emptyList()
            return AICommandResult.Ask(listOf(AskQuestion("", question, false, options.map { AskOption(it) })))
        }
        val anyTool = webSearchEnabled || memoryEnabled || health || travel || news || loadSkill
        if (anyTool) {
            payload.optString("tool").takeIf { it.isNotEmpty() }?.let { name ->
                return parseToolCall(payload, name, webSearchEnabled, memoryEnabled, health, travel, news, loadSkill)
                    ?: throw DeepSeekException(
                        Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value) + " $name")
            }
        }
        var rawActions = payload.optJSONArray("actions")
        // 单条操作直接摊在顶层、漏了 actions 外壳:当成只有一条处理。
        if ((rawActions == null || rawActions.length() == 0) && payload.optString("action").isNotEmpty()) {
            rawActions = JSONArray().put(payload)
        }
        if (rawActions == null || rawActions.length() == 0) {
            // 没有任何操作、却捎了一句话回来:这是它在回话,不是故障。
            listOf("reply", "answer", "text", "message", "response", "content")
                .firstNotNullOfOrNull { payload.optString(it).trim().takeIf { t -> t.isNotEmpty() } }
                ?.let { return AICommandResult.Actions(listOf(AIAction.Answer(it))) }
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 actions", CurrentLang.value))
        }
        // ReAct 工具被塞进 actions 数组且只有这一条:按工具调用处理。
        if (rawActions.length() == 1 && anyTool) {
            val only = rawActions.optJSONObject(0)
            val name = only?.optString("tool")?.takeIf { it.isNotEmpty() } ?: only?.optString("action").orEmpty()
            if (only != null) parseToolCall(only, name, webSearchEnabled, memoryEnabled, health, travel, news, loadSkill)?.let { return it }
        }
        val actions = mutableListOf<AIAction>()
        for (i in 0 until rawActions.length()) {
            val raw = rawActions.getJSONObject(i)
            fun validUuid(): String = canonicalId(raw.optString("uuid"), validUuids)
                ?: throw DeepSeekException(Strings.translate("无法解析:找不到要操作的事项", CurrentLang.value))
            fun unknown(name: String): Nothing = throw DeepSeekException(
                Strings.translate("无法解析:返回格式异常:未知 action", CurrentLang.value) +
                    (if (name.isNotEmpty()) " $name" else ""))
            fun nonEmpty(key: String, detail: String): String = raw.optString(key).trim().ifEmpty {
                throw DeepSeekException(Strings.translate("无法解析:返回格式异常:$detail", CurrentLang.value))
            }
            when (val action = raw.optString("action")) {
                "create" -> actions += AIAction.Create(parsePayload(raw))
                "update" -> actions += AIAction.Update(validUuid(), parsePayload(raw))
                "complete" -> actions += AIAction.Complete(validUuid())
                "delete" -> actions += AIAction.Delete(validUuid())
                "answer" -> actions += AIAction.Answer(nonEmpty("text", "回答内容为空"))
                "remember_preference" -> actions += AIAction.RememberPreference(nonEmpty("text", "偏好内容为空"))
                "memorize" -> if (memoryEnabled) actions += AIAction.Memorize(nonEmpty("text", "收藏内容为空")) else unknown(action)
                "suggest_memorize" -> if (memoryEnabled) actions += AIAction.SuggestMemorize(nonEmpty("text", "建议收藏内容为空")) else unknown(action)
                "ask_memory" -> if (memoryEnabled) actions += AIAction.AskMemory(nonEmpty("question", "查询问题为空")) else unknown(action)
                "auto_memorize" -> if (memoryEnabled) {
                    val title = raw.optString("title").trim()
                    val text = raw.optString("text").trim()
                    if (title.isEmpty() || text.isEmpty()) {
                        throw DeepSeekException(Strings.translate("无法解析:返回格式异常:自动记录内容为空", CurrentLang.value))
                    }
                    actions += AIAction.AutoMemorize(title, text)
                } else unknown(action)
                "plan_trip" -> if (tripPlan) actions += AIAction.PlanTrip(parseTripPlan(raw, now)) else unknown(action)
                "edit_trip" -> if (travel) actions += AIAction.EditTrip(parseTripEdit(raw)) else unknown(action)
                "create_countdown", "update_countdown", "delete_countdown" ->
                    if (countdown) actions += AIAction.Countdown(parseCountdownOp(raw, action, validCountdownIds)) else unknown(action)
                "create_asset", "update_asset" ->
                    if (assets) actions += AIAction.Asset(parseAssetOp(raw, action, validAssetIds)) else unknown(action)
                "subscribe_feed", "update_feed" ->
                    if (feeds) parseFeedOps(raw, action, validFeedIds).forEach { actions += AIAction.Feed(it) } else unknown(action)
                else -> unknown(action)
            }
        }
        // 倒数日/资产/订阅:直接执行、不参与问答归一化,排在前面(同 iOS)。
        val direct = actions.filter { it is AIAction.Countdown || it is AIAction.Asset || it is AIAction.Feed }
        val rest = actions - direct.toSet()
        if (rest.isEmpty()) return AICommandResult.Actions(direct)
        // 归一化:问答类(answer/ask_memory/suggest_memorize/plan_trip/edit_trip)和写操作混在
        // 一起时丢掉问答类;全是问答类时只留第一条。
        fun informational(a: AIAction) = a is AIAction.Answer || a is AIAction.AskMemory ||
            a is AIAction.SuggestMemorize || a is AIAction.PlanTrip || a is AIAction.EditTrip
        val info = rest.filter(::informational)
        if (info.isNotEmpty()) {
            return if (info.size == rest.size) AICommandResult.Actions(direct + rest[0])
            else AICommandResult.Actions(direct + rest.filterNot(::informational))
        }
        return AICommandResult.Actions(direct + rest)
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

    // ---------------- 这一轮从 iOS 移植的 AI 小请求(同 prompt) ----------------

    /** 应用内语言对应的写作语言名。 */
    fun languageName(): String = if (CurrentLang.value == com.lodo.app.core.Lang.EN) "English" else "中文"

    private fun requireText(payload: JSONObject, key: String): String =
        payload.optString(key).trim().ifEmpty {
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 $key", CurrentLang.value))
        }

    /** 总览:一句今天任务的处理建议。 */
    suspend fun suggestTodayHandling(config: AIConfig, summary: String): String {
        val system = "你是提醒事项应用 lodo 的今日助手。根据今天的待办列表(可能含到期未处理的)," +
            "给一句不超过 60 个字的处理建议:侧重优先级和取舍,具体可执行," +
            "不要\"合理安排时间\"这类空话。只返回 JSON:{\"suggestion\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        return requireText(complete(config, system, summary, timeoutSeconds = 60), "suggestion")
    }

    /** 总览:一句今天新收藏的记忆总结。 */
    suspend fun summarizeTodayMemories(config: AIConfig, summary: String): String {
        val system = "你是提醒事项应用 lodo 的记忆助手。根据今天新收藏的记忆条目(标题+摘要)," +
            "用一句不超过 60 个字的话总结今天收藏了什么、有没有共同点或值得注意的地方。" +
            "只返回 JSON:{\"summary\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        return requireText(complete(config, system, summary, timeoutSeconds = 60), "summary")
    }

    /** 倒数页顶部那一句。 */
    suspend fun countdownInsight(config: AIConfig, summary: String): String {
        val language = languageName()
        val system = "你是提醒事项应用 lodo 的倒数日助手。下面是用户记下的日子:还没到的(倒数日)和已经" +
            "过去、在往上数的(正数日,如在一起、入职、宝宝出生),以及它们接下来的节点(周年、整百天)。" +
            "挑今天**最值得一提**的一两件,用${language}写一句不超过 30 个字(英文不超过 20 个词)的话:像朋友提醒,有温度、具体," +
            "比如\"在一起马上两周年啦,想想怎么庆祝\"\"还有 5 天考研,稳住\"。\n规则:\n" +
            "- 每一行是**一件**事,节点(几天后开始、满几周年、满几百天)只属于它那一行;" +
            "**不要把两件事的节点拼到一起**(A 三天后开始、B 三天后满周年,不能写成\"A 三天后满周年\")。\n" +
            "- 提到的事用列表里「」中的名字,可以略去修饰但不能换成别的事。\n" +
            "- 只根据列出的事实写,不编日子、不编数字;没什么特别的就说离得最近的那件。\n" +
            "只返回 JSON:{\"text\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        return requireText(complete(config, system, summary, timeoutSeconds = 60), "text")
    }

    /** 总览:一句今天的健康提示。 */
    suspend fun suggestTodayHealth(config: AIConfig, summary: String): String {
        val system = "你是提醒事项应用 lodo 的健康助手。根据最近几天的健康数据汇总," +
            "给一句不超过 60 个字的提示:指出一个最值得注意的变化,并给一个具体可做的小建议," +
            "不要\"注意身体\"\"保持健康\"这类空话。你不是医生,不做诊断、不提药物;" +
            "数据明显异常时提示去看医生即可。只返回 JSON:{\"suggestion\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        return requireText(complete(config, system, summary, timeoutSeconds = 60), "suggestion")
    }

    data class HealthAnalysis(val analysis: String, val suggestions: List<String>)

    /** 健康页:一段分析 + 最多 3 条建议。 */
    suspend fun analyzeHealth(config: AIConfig, summary: String, memoryContext: String? = null): HealthAnalysis {
        val system = "你是提醒事项应用 lodo 的健康助手。根据用户最近几天的健康数据汇总" +
            "(可能附带用户自己收藏的健康资料),写一段不超过 150 个字的分析:" +
            "说清楚哪些指标在变好、哪些在变差、可能的原因,再给最多 3 条具体可执行的建议。" +
            "你不是医生:不做诊断、不推荐药物、不解读化验值的临床意义;" +
            "发现明显异常时,请建议用户去看医生。" +
            "只返回 JSON:{\"analysis\": \"一段话\", \"suggestions\": [\"建议1\", \"建议2\"]},不要任何其他文字。" + personaBlock(config)
        val user = memoryContext?.let { "$summary\n\n用户收藏的健康资料:\n$it" } ?: summary
        val payload = complete(config, system, user, timeoutSeconds = 90)
        return HealthAnalysis(requireText(payload, "analysis"), strings(payload.optJSONArray("suggestions")).take(3))
    }

    private fun strings(arr: JSONArray?): List<String> = arr?.let { a ->
        (0 until a.length()).mapNotNull { a.optString(it).trim().takeIf(String::isNotEmpty) }
    } ?: emptyList()

    /** 旅行卡片上那句备注,口径同 plan_trip 的 summary。 */
    suspend fun suggestTripNote(config: AIConfig, summary: String): String {
        val system = "你是旅行应用 lodo 的旅行助手。根据这次旅行的名字、日期和行程," +
            "写一句写在旅行卡片上的话:**20 个字以内**,有人情味,像朋友送行时说的——" +
            "\"好好享受这趟白雪之旅\"\"慢慢逛,别赶\"\"吃好睡好,把京都的秋天看够\"。" +
            "不要复述排程逻辑(\"避开航班时段\"\"按地理位置串联\"\"每天安排三个景点\"这类一律不要)," +
            "不要列行程,不要加引号。只返回 JSON:{\"note\": \"一句话\"},不要任何其他文字。" + personaBlock(config)
        return requireText(complete(config, system, summary, timeoutSeconds = 60), "note")
    }

    /** 重新选点时的 AI 校准:每个地点从 OSM 候选里挑用户真正要去的那一个(prompt 同 iOS calibratePlaces)。 */
    suspend fun calibratePlaces(
        config: AIConfig, trip: String, items: List<com.lodo.app.core.PlaceCalibration.Item>,
    ): Map<String, com.lodo.app.core.PlaceCalibration.Choice> {
        if (items.isEmpty()) return emptyMap()
        val system = """你是旅行应用 lodo 的地图助手。用户旅行里的每个地点都在 OpenStreetMap 上搜到了几个同名或近似的候选,你要替每个地点挑出用户**真正要去的那一个**。

只返回 JSON:{"choices": [{"id": "地点的 id", "pick": 候选编号}]},每个地点一条,不要任何其他文字。编号从 1 开始;所有候选都明显不对时 pick 写 null。

判断依据,按重要程度:
- 位置要和这趟旅行对得上:目的地城市、同一天其他地点在哪。同一天的地点一般在同一个城市或相邻城市;离目的地几百公里的候选,除非行程里写了当天去那里,否则不选。
- 类型要对得上:景点选景点本身(寺庙、公园、博物馆),不选同名的车站、公交站、停车场、商店;住宿选酒店本身,不选旁边的车站或商场;写的是区域(「新宿」「浅草」)时选那个区域或它的中心,不选区域里某家店。
- 名字要真的是同一个地方:只是有几个字相同(「新宿王子酒店」对「喜多屋酒店仓库」)不算。
- 同样合适时选知名度高的——游客去的多半是有名的那一座。
- 拿不准也要选一个最可能的;只有所有候选都明显是另一个地方时才写 null。"""
        val user = com.lodo.app.core.PlaceCalibration.prompt(trip, items)
        return com.lodo.app.core.PlaceCalibration.parse(complete(config, system, user, timeoutSeconds = 90), items)
    }

    data class PackingSuggestion(val title: String, val category: String, val reason: String)

    suspend fun suggestPackingList(config: AIConfig, summary: String, existing: List<String>): List<PackingSuggestion> {
        val language = languageName()
        val system = "你是旅行应用 lodo 的行李助手。根据用户这次旅行的目的地、日期(季节、天数)和行程" +
            "(有没有温泉、徒步、海边、正式场合、长途飞行),建议要带的东西,用${language}写。\n\n" +
            "只返回 JSON:{\"items\": [{\"title\": \"物品\", \"category\": \"分类\", \"reason\": \"为什么带\"}]}," +
            "不要任何其他文字。\n\n规则:\n- 12 到 30 件,按重要程度排,证件和钱最先。\n" +
            "- category 从这几个里选:证件、钱与卡、衣物、电子、洗护、药品、其他。\n" +
            "- title 写具体的东西(\"转换插头(日本 A 型)\"\"薄羽绒服\"),不写\"必需品\"\"衣服若干\"。\n" +
            "- reason 一句话、15 字以内,说和这趟旅行有关的理由(\"十一月京都早晚凉\"\"有温泉\");" +
            "人人都带的(牙刷、手机)可以留空。\n- 已有清单里有的不要再建议。"
        val owned = if (existing.isEmpty()) "(还没有)" else existing.joinToString("、")
        val payload = complete(config, system, "$summary\n\n已有清单:$owned", timeoutSeconds = 60)
        val arr = payload.optJSONArray("items")
            ?: throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 items", CurrentLang.value))
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val title = o.optString("title").trim().ifEmpty { return@mapNotNull null }
            PackingSuggestion(title, o.optString("category").trim().ifEmpty { "其他" }, o.optString("reason").trim())
        }
    }

    data class ParsedTravelItem(
        val kind: com.lodo.app.core.TravelItemKind, val title: String, val code: String?,
        val start: LocalDateTime?, val end: LocalDateTime?, val placeName: String?, val originName: String?,
        val price: Double?, val currency: String?, val note: String, val transport: com.lodo.app.core.TransportDetails?,
    )

    /** 订单/确认单/行程单文本 → 行程项(调用方先给用户确认再落库)。prompt 同 iOS parseTravelItems。 */
    suspend fun parseTravelItems(
        config: AIConfig, text: String, tripTitle: String, tripStart: LocalDateTime, tripEnd: LocalDateTime,
    ): List<ParsedTravelItem> {
        val system = """你是旅行助手。从用户给的订单/确认单/行程单/登机牌/航班动态文本里,抽取出所有行程项。文本可能是截图 OCR 出来的,会有断行、串行、错字,按常识理解。
当前这趟旅行叫「$tripTitle」,日期范围 ${tripStart.format(dateFormatter)} 到 ${tripEnd.format(dateFormatter)}。

只返回 JSON:{"items": [行程项, ...]},不要任何其他文字。每个行程项:
{"kind": "flight|train|coach|lodging|place", "title": "简短名称", "code": "航班号/车次/订单号,没有就省略", "start": "yyyy-MM-dd HH:mm", "end": "yyyy-MM-dd HH:mm", "place": "主要地点(住宿/地点填它本身,航班/火车/客车填**到达地**)", "origin": "航班/火车/客车的出发地,其余类型省略", "price": 数字, "currency": "ISO 4217 币种码如 CNY/JPY/USD", "note": "补充说明", "flight": 交通补充信息,flight/train/coach 才有,见下}

交通补充信息(航班、火车、客车共用这个对象;每个字段都是可选的,文本里没有就省略,整个对象都没有就省略 flight):
{"airline": "航空公司/铁路公司/客运公司", "departure_code": "出发机场三字码如 PEK", "arrival_code": "到达机场三字码", "departure_timezone": "出发地时区,IANA 标识如 Asia/Tokyo", "arrival_timezone": "到达地时区,IANA 标识", "departure_terminal": "出发航站楼如 T3", "arrival_terminal": "到达航站楼", "check_in_counter": "值机柜台/值机岛", "gate": "航班填登机口,火车/客车填检票口", "platform": "火车站台,客车填上车点", "carriage": "火车车厢号", "boarding_time": "yyyy-MM-dd HH:mm", "estimated_departure": "yyyy-MM-dd HH:mm", "estimated_arrival": "yyyy-MM-dd HH:mm", "seat": "座位号", "cabin": "航班舱位如 经济舱,火车座席如 二等座/指定席", "aircraft": "机型如 空客A330", "baggage_belt": "行李转盘", "status": "scheduled|check_in|boarding|gate_closed|departed|delayed|arrived|canceled|diverted"}

规则:
- 往返机票是**两条** flight,别合成一条;火车票、大巴票同理,一程一条。
- 高铁/动车/城际按 train,长途大巴/机场大巴/旅游巴士按 coach;车次填进 code。
- 航班的 start/end 填**计划**起降时刻;航班动态里显示的变更后/预计时刻填 estimated_departure/estimated_arrival,不要覆盖到 start/end 上。只有预计时刻、看不到计划时刻时省略 start/end。
- **所有时刻都照抄票面上的当地时间**:出发时刻是出发地的当地时间,到达时刻是到达地的当地时间,不要换算成别的时区。
- departure_timezone/arrival_timezone 按出发地、到达地所在城市给出 IANA 时区(北京、上海 → Asia/Shanghai,东京、大阪 → Asia/Tokyo,首尔 → Asia/Seoul,巴黎 → Europe/Paris);城市看不出来就省略,别猜。
- status 只在文本明确写了状态(如"延误""登机中""已取消")时填,别从时间推断;火车、客车一般没有。
- 登机口、座位这些照抄原文,读不清就省略,别猜。
- 住宿的 start 是入住、end 是退房。
- 年份没写明时按上面给的旅行日期范围推断,不要凭空用今年。
- 时间拿不准就省略 start/end,别编一个;金额拿不准就省略 price。
- 文本里没有任何行程信息时返回 {"items": []}。""" + personaBlock(config)
        return parseTravelPayload(complete(config, system, text, timeoutSeconds = 90))
    }

    internal fun parseTravelPayload(payload: JSONObject): List<ParsedTravelItem> {
        val arr = payload.optJSONArray("items")
            ?: throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 items", CurrentLang.value))
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val kind = com.lodo.app.core.TravelItemKind.from(o.text("kind")) ?: return@mapNotNull null
            val title = o.text("title") ?: return@mapNotNull null
            ParsedTravelItem(
                kind, title, o.text("code"), parsePlanDate(o.text("start")), parsePlanDate(o.text("end")),
                o.text("place"), o.text("origin"), o.number("price"), o.text("currency")?.uppercase(),
                o.text("note") ?: "",
                if (kind.isTransport) com.lodo.app.core.TransportDetails.parse(o.optJSONObject("flight")) else null,
            )
        }
    }

    data class ParsedMenuDish(val originalName: String, val translatedName: String, val intro: String, val category: String, val price: Double?)
    data class ParsedMenu(val restaurant: String, val sourceLanguage: String, val currency: String?, val dishes: List<ParsedMenuDish>)

    /** 菜单文字(OCR 或粘贴)→ 菜品清单 + 翻译,prompt 同 iOS parseMenu。不给确认页,整理完直接落库。 */
    suspend fun parseMenu(config: AIConfig, text: String, targetLanguage: String = languageName()): ParsedMenu {
        val t = targetLanguage
        val system = """你是点餐助手。用户给的是一张菜单上的文字,可能来自拍照/截图的 OCR,会有断行、串行、错字。把它整理成菜品清单,并翻译成$t。

只返回 JSON:{"restaurant": "店名,菜单上没印就省略", "language": "菜单原文是什么语言,用${t}说,如 日语;认不出来就省略", "currency": "ISO 4217 币种码如 CNY/JPY/EUR,只有符号认不准就省略", "dishes": [菜品, ...]},不要任何其他文字。每道菜:
{"original": "菜单上的原文名称,照抄不要翻译", "translated": "${t}译名", "category": "分类如 前菜/主菜/甜点/饮品,用${t}写", "price": 数字, "description": "一句不超过 40 字的介绍:主要食材、做法、口味"}

规则:
- 只整理菜品。店名、地址、电话、营业时间、"本店谢绝自带酒水"这类说明文字都不是菜。
- original 照抄菜单原文,不要把译名写进去;菜单本来就是${t}时,translated 填和 original 一样的文字。
- category 优先用菜单上印的分类;菜单没分类就按常识归类,归不出来就省略。
- description 一定要给:菜单只写了菜名、或者名字看不出是什么(如"月见とろろ")时,按常识补全说明这是什么菜;拿不准就在句子里说明是推测,不要编造具体做法。
- price 只填数字,不带货币符号;菜单没标价就省略 price,不要填 0。
- OCR 串行、错字明显的按常识修正成合理的菜名,不要原样保留乱码。
- 一道菜也读不出来时返回 {"dishes": []}。""" + personaBlock(config)
        return parseMenuPayload(complete(config, system, text, timeoutSeconds = 90))
    }

    internal fun parseMenuPayload(payload: JSONObject): ParsedMenu {
        val arr = payload.optJSONArray("dishes")
            ?: throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 dishes", CurrentLang.value))
        val dishes = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val original = o.text("original") ?: o.text("translated") ?: return@mapNotNull null
            val price = o.number("price") ?: o.text("price")?.filter { it.isDigit() || it == '.' }?.toDoubleOrNull()
            ParsedMenuDish(original, o.text("translated") ?: "", o.text("description") ?: "", o.text("category") ?: "", price)
        }
        return ParsedMenu(payload.text("restaurant") ?: "", payload.text("language") ?: "", payload.text("currency")?.uppercase(), dishes)
    }

    data class ArticleSummary(val summary: String, val points: List<String>) {
        fun toJson(): String = JSONObject().put("summary", summary).put("points", JSONArray(points)).toString()

        companion object {
            fun decode(json: String?): ArticleSummary? = json?.let {
                runCatching {
                    val o = JSONObject(it)
                    ArticleSummary(o.optString("summary"), (0 until (o.optJSONArray("points")?.length() ?: 0))
                        .map { i -> o.getJSONArray("points").optString(i) })
                }.getOrNull()
            }
        }
    }

    suspend fun summarizeArticle(config: AIConfig, title: String, source: String, text: String, language: String = languageName()): ArticleSummary {
        val system = "你是阅读助手。用户给你一篇文章(标题、来源和正文,正文可能是网页抽出来的纯文本," +
            "夹着导航、广告、评论等无关文字,忽略它们),用${language}总结。\n\n" +
            "只返回 JSON:{\"summary\": \"两三句话讲清这篇文章说了什么、结论是什么\", " +
            "\"points\": [\"要点\", ...]},不要任何其他文字。\n\n规则:\n" +
            "- summary 不超过 120 字;points 3 到 5 条,每条不超过 40 字,讲具体事实、数字、观点," +
            "不写\"文章介绍了…\"这种空话。\n" +
            "- 原文是别的语言时照样用${language}总结,专有名词第一次出现可以括号带原文。\n" +
            "- 只根据给的内容总结,不补充文章里没有的信息;正文只有一两句时就照实简短总结。"
        val payload = complete(config, system, "标题:$title\n来源:$source\n\n正文:\n${text.take(12000)}", timeoutSeconds = 60)
        return ArticleSummary(requireText(payload, "summary"), strings(payload.optJSONArray("points")).take(5))
    }

    data class NewsDigestItem(val title: String, val detail: String, val refs: List<Int>)
    data class NewsDigest(val overview: String, val items: List<NewsDigestItem>)

    suspend fun newsDigest(config: AIConfig, headlines: String, language: String = languageName()): NewsDigest {
        val system = "你是新闻编辑。下面是用户订阅的新闻和博客里最近的文章清单(每行开头是编号," +
            "后面是来源、标题、时间、摘要)。只挑出今天**最重要**的几件事,写成一份简报。\n\n" +
            "只返回 JSON:{\"overview\": \"一句话概括今天最重要的事,不超过 40 字\", " +
            "\"items\": [{\"title\": \"这件事本身,一句话说清发生了什么\", " +
            "\"detail\": \"关键事实和影响,不超过 60 字\", \"refs\": [这条依据的文章编号]}]}," +
            "不要任何其他文字。\n\n规则:\n" +
            "- refs 写这条依据的是清单里哪几篇(编号,1 到 3 个),只写真的讲了这件事的那几篇。\n" +
            "- items 3 到 5 条,按重要程度排,最重要的放第一条;多个来源讲同一件事的合并成一条。\n" +
            "- 只写事情本身,**不写来源、媒体名、作者**,也不写\"某某报道\"\"据某某\"。\n" +
            "- 重要程度看影响面和新鲜度:政策、市场、行业大事、重大发布优先;软文、清单、" +
            "个人随笔、周刊目录这类没有\"事\"的内容不要选。\n" +
            "- 用${language}写,别的语言的标题翻译过来;只根据清单里的内容写,不编造清单里没有的细节。\n" +
            "- 清单里只有零星几条时就照实少写,不要凑数。" + personaBlock(config)
        val payload = complete(config, system, headlines, timeoutSeconds = 60)
        val arr = payload.optJSONArray("items") ?: JSONArray()
        val items = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val title = o.text("title") ?: return@mapNotNull null
            val refsArr = o.optJSONArray("refs") ?: JSONArray()
            val refs = (0 until refsArr.length()).mapNotNull { j ->
                when (val v = refsArr.opt(j)) {
                    is Number -> v.toInt()
                    is String -> v.trim('[', ']', ' ').toIntOrNull()
                    else -> null
                }
            }
            NewsDigestItem(title, o.optString("detail").trim(), refs)
        }
        val overview = payload.optString("overview").trim()
        if (items.isEmpty() && overview.isEmpty()) {
            throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 items", CurrentLang.value))
        }
        return NewsDigest(overview, items)
    }

    /** 把一段更早的对话压成常驻摘要(滚动摘要),同 iOS summarizeConversation。 */
    suspend fun summarizeConversation(config: AIConfig, previous: String?, transcript: String): String {
        val system = "你是提醒事项应用 lodo 的对话记忆整理助手。下面是用户与 AI 助手更早的一段对话," +
            "请把它压缩成一段摘要,供之后的对话理解上下文。" +
            "保留:用户说过的事实与偏好、已经执行过的操作及其结果(新建/修改/完成了什么、" +
            "收藏了什么、规划或调整了哪次行程)、还没了结的话题。" +
            "丢弃:寒暄、重复的确认、纯粹的客套。用第三人称陈述,不要复述原话。" +
            (if (previous == null) "" else "已有摘要要一并合并进来,不要丢掉它里面的事实。") +
            "只返回 JSON:{\"summary\": \"摘要正文\"},不要任何其他文字。"
        val user = previous?.let { "已有摘要:\n$it\n\n新增对话:\n$transcript" } ?: transcript
        return requireText(complete(config, system, user, timeoutSeconds = 60), "summary")
    }

    /** 偏好超过 40 条时归纳合并,同 iOS consolidatePreferences。 */
    suspend fun consolidatePreferences(config: AIConfig, current: String): String {
        val system = "你是提醒事项应用 lodo 的偏好整理助手。下面是 AI 在对话里陆续记下的用户长期做事偏好," +
            "一行一条。把它们归纳合并:相同或相近的合成一条,前后矛盾的以后面的为准,最多 25 条," +
            "每条一句陈述句。只返回 JSON:{\"preferences\": [\"一条偏好\", ...]},不要任何其他文字。"
        val payload = complete(config, system, current, timeoutSeconds = 60)
        return strings(payload.optJSONArray("preferences")).joinToString("\n")
    }

    /** 定时任务带订阅新闻的版本(Android 仍是单轮直接作答,不带 ReAct)。 */
    /** 定时任务这一轮的结果:最终文字,或要先用一次联网工具(同 iOS AIRoutineOutcome)。 */
    sealed interface RoutineOutcome {
        data class Text(val text: String) : RoutineOutcome
        data class Tool(val thought: String, val search: String?, val fetch: String?) : RoutineOutcome
    }

    /** 可离线单测的纯解析(同 iOS parseRoutine):联网没开时工具调用一律不认。 */
    fun parseRoutine(payload: JSONObject, webSearchEnabled: Boolean): RoutineOutcome {
        val tool = payload.optString("tool").trim()
        if (webSearchEnabled && tool.isNotEmpty()) {
            val thought = payload.optString("thought")
            return when (tool) {
                "web_search" -> RoutineOutcome.Tool(thought, payload.optString("query").trim().ifEmpty {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:web_search 缺少 query", CurrentLang.value)) }, null)
                "web_fetch" -> RoutineOutcome.Tool(thought, null, payload.optString("url").trim().ifEmpty {
                    throw DeepSeekException(Strings.translate("无法解析:返回格式异常:web_fetch 缺少 url", CurrentLang.value)) })
                else -> throw DeepSeekException(Strings.translate("无法解析:返回格式异常:未知工具 ", CurrentLang.value) + tool)
            }
        }
        return RoutineOutcome.Text(requireText(payload, "text"))
    }

    /**
     * 定时任务,带 ReAct 联网(同 iOS runRoutine + RoutineRunner):配了 Tavily key 才给工具,
     * 合计最多两次,工具结果拼进下一轮用户消息(Android ReAct 的一贯写法,语义同 iOS 的 history 条目)。
     */
    suspend fun runRoutineWithTools(
        config: AIConfig, prompt: String, newsContext: String?, taskContext: String?, tavilyKey: String?,
    ): String {
        val web = !tavilyKey.isNullOrBlank()
        var user = prompt
        repeat(3) { round ->
            val payload = runRoutinePayload(config, user, newsContext, taskContext, web && round < 2)
            when (val out = parseRoutine(payload, web && round < 2)) {
                is RoutineOutcome.Text -> return out.text
                is RoutineOutcome.Tool -> {
                    val observation = runCatching {
                        if (out.search != null) WebSearchClient.search(tavilyKey!!, out.search)
                            .joinToString("\n") { "- ${it.title}:${it.snippet.take(300)}(${it.url})" }.ifBlank { "(没有搜到结果)" }
                        else WebSearchClient.fetchUrl(out.fetch!!)
                    }.getOrElse { "(工具调用失败:${it.message})" }
                    user += "\n\n[" + (if (out.search != null) "搜索「${out.search}」的结果" else "链接 ${out.fetch} 的内容") + "]\n" + observation
                }
            }
        }
        throw DeepSeekException(Strings.translate("无法解析:返回格式异常:缺少 text", CurrentLang.value))
    }

    suspend fun runRoutine(config: AIConfig, prompt: String, newsContext: String?, taskContext: String?): String =
        requireText(runRoutinePayload(config, prompt, newsContext, taskContext, false), "text")

    private suspend fun runRoutinePayload(config: AIConfig, prompt: String, newsContext: String?, taskContext: String?, tools: Boolean): JSONObject {
        val tasks = taskContext?.let { "\n\n今天的待办:\n$it" } ?: ""
        val news = newsContext?.let { "\n\n用户订阅的新闻与博客(最近的文章):\n$it" } ?: ""
        val system = "你是提醒事项应用 lodo 的定时任务助手。用户预先设定了一条会自动执行的例行任务," +
            "现在到了执行时间,你要按用户写的指令生成这一次的内容,直接展示给用户看。\n\n要求:\n" +
            "- 只输出这次要说的内容本身,不要复述指令,不要开场白和客套话。\n" +
            "- 具体、可执行,不说\"合理安排时间\"\"注意身体\"这类空话。\n" +
            "- 不超过 120 个字,一段纯文本,不要 markdown 标题或列表符号。\n" +
            "- 信息不足时按常理给出最有用的内容,不要反问用户——定时任务没有人能回答你。\n\n" +
            "只返回 JSON:{\"text\": \"这次要展示给用户的内容\"},不要任何其他文字。" +
            (if (tools) AgentSkillStore.routineWebTools() else "") + "\n\n" +
            timeContext() + tasks + news + personaBlock(config)
        return complete(config, system, prompt, timeoutSeconds = 60)
    }

    private fun taskJson(task: ParsedTask): JSONObject = JSONObject()
        .put("title", task.title)
        .put("remind_at", task.remindAt.format(dateFormatter))
        .put("all_day", task.allDay)
        .put("duration_minutes", task.durationMinutes)
        .put("repeat_type", task.repeatType.raw)
        .put("repeat_days", JSONArray(task.repeatDays))
        .put("repeat_times", JSONArray(task.repeatTimes))
        .put("project", task.project)

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

    /** 不支持流式的服务地址(非 200 / 一个字没收到),这次进程里不再试;不落盘,重开 app 会再试。 */
    private val unsupportedStreamEndpoints = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    /** 不认 stream_options 的网关:去掉它再试一次流式,不为了 token 数把能用的流式整条拉黑。 */
    private val usageUnsupportedStreamEndpoints = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /**
     * 流式请求(同 iOS cloudStream):累加 SSE 的 content 增量,`AnswerStreamScanner` 只把确认是
     * answer 的正文吐给 onStream,收完后交给同一个 decodePayload。回退矩阵:网关不支持 / 非 200 /
     * 一个字没收到 / 攒出来的串解析不了,一律退回一次性请求,**退之前先 onStream("") 清掉已经
     * 显示的半句**。中途断流且已经吐过字时**不重试**(会出现两遍文本),直接报错。
     */
    private suspend fun completeStreaming(
        config: AIConfig, system: String, user: String, timeoutSeconds: Long, thinking: Boolean,
        onStream: (String) -> Unit, onReasoning: (String) -> Unit,
    ): JSONObject = withContext(Dispatchers.IO) {
        suspend fun fallback(): JSONObject {
            onStream("")
            AIUsageMonitor.discardRequest()
            return complete(config, system, user, timeoutSeconds = timeoutSeconds, thinking = thinking)
        }
        if (config.apiKey.isNullOrBlank() || config.endpoint.isBlank() || config.endpoint in unsupportedStreamEndpoints) {
            return@withContext fallback()
        }
        val includeUsage = config.endpoint !in usageUnsupportedStreamEndpoints
        val body = JSONObject()
            .put("model", config.model)
            .put("messages", JSONArray()
                .put(JSONObject().put("role", "system").put("content", system))
                .put(JSONObject().put("role", "user").put("content", user)))
            .put("response_format", JSONObject().put("type", "json_object"))
            .put("temperature", 0)
            .put("stream", true)
        if (thinking && !config.reasoningEffort.isNullOrBlank() && config.reasoningEffort != "off") {
            body.put("reasoning_effort", config.reasoningEffort)
        }
        if (includeUsage) body.put("stream_options", JSONObject().put("include_usage", true))
        val request = Request.Builder().url(config.endpoint)
            .header("Authorization", "Bearer ${config.apiKey}")
            .header("Accept", "text/event-stream")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        val call = client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS).build().newCall(request)
        // 协程取消时掐断这条连接,阻塞着的读会立刻抛出来。
        val cancelHandle = coroutineContext[kotlinx.coroutines.Job]?.invokeOnCompletion { if (it != null) call.cancel() }
        val scanner = com.lodo.app.core.AnswerStreamScanner()
        val throttle = com.lodo.app.core.StreamThrottle()
        val raw = StringBuilder()
        AIUsageMonitor.beginRequest()
        try {
            val response = try { call.execute() } catch (e: IOException) {
                ensureActive()
                return@withContext fallback()
            }
            response.use { resp ->
                if (resp.code != 200) {
                    if (includeUsage) {
                        usageUnsupportedStreamEndpoints += config.endpoint
                        return@withContext completeStreaming(config, system, user, timeoutSeconds, thinking, onStream, onReasoning)
                    }
                    unsupportedStreamEndpoints += config.endpoint
                    return@withContext fallback()
                }
                val source = resp.body?.source() ?: return@withContext fallback()
                try {
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        when (val event = com.lodo.app.core.AgentStream.parseLine(line)) {
                            com.lodo.app.core.AgentStream.Event.Done -> break
                            is com.lodo.app.core.AgentStream.Event.Usage -> AIUsageMonitor.report(event.input, event.output)
                            is com.lodo.app.core.AgentStream.Event.Delta -> {
                                AIUsageMonitor.noteDelta()
                                event.reasoning?.takeIf { it.isNotEmpty() }?.let(onReasoning)
                                val content = event.content?.takeIf { it.isNotEmpty() } ?: continue
                                raw.append(content)
                                val text = scanner.consume(content)
                                if (text != null && throttle.shouldFlush(content)) onStream(text)
                            }
                            else -> {}
                        }
                    }
                } catch (e: IOException) {
                    ensureActive()
                    if (raw.isNotEmpty()) throw DeepSeekException(
                        Strings.translate("调用 DeepSeek 失败:", CurrentLang.value) + e.message)
                    return@withContext fallback()
                }
            }
        } finally {
            cancelHandle?.dispose()
        }
        // 节流可能压住了最后几片,收完补一次。
        if (scanner.currentText.isNotEmpty()) onStream(scanner.currentText)
        if (raw.isNotEmpty()) AIUsageMonitor.endRequest()
        if (raw.isEmpty()) {
            unsupportedStreamEndpoints += config.endpoint
            return@withContext fallback()
        }
        val payload = try {
            decodePayload(raw.toString())
        } catch (e: DeepSeekException) {
            // 有花括号但给坏了(多半是截断):退回一次性请求重来一遍。
            return@withContext fallback()
        }
        payload.optString("error").takeIf { it.isNotEmpty() }?.let {
            throw ModelErrorException(Strings.translate("无法解析:", CurrentLang.value) + it)
        }
        payload
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
            // 用量只统计 command(thinking = true 的唯一入口);量不到首片时间,只能按整次请求耗时(偏慢)。
            if (thinking) AIUsageMonitor.beginRequest()
            val response = try { executeWithRetry(call, request) } catch (e: Exception) {
                if (thinking) AIUsageMonitor.discardRequest()
                throw e
            }

            response.use { resp ->
                val text = resp.body?.string().orEmpty()
                if (thinking && resp.code == 200) {
                    runCatching { JSONObject(text).optJSONObject("usage") }.getOrNull()?.let { u ->
                        AIUsageMonitor.report(u.optInt("prompt_tokens").takeIf { u.has("prompt_tokens") }, u.optInt("completion_tokens").takeIf { u.has("completion_tokens") })
                    }
                    AIUsageMonitor.endRequest()
                }
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
                    throw ModelErrorException(Strings.translate("无法解析:", CurrentLang.value) + it)
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
            project = payload.optString("project").trim(),
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
