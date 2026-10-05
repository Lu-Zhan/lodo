package com.lodo.app.ui.agent

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.ai.AIAction
import com.lodo.app.ai.AICommandResult
import com.lodo.app.ai.AITool
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AskQuestion
import com.lodo.app.ai.CommandCapabilities
import com.lodo.app.ai.CommandContext
import com.lodo.app.ai.CountdownPromptEntry
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.FeedPromptEntry
import com.lodo.app.ai.WebSearchClient
import com.lodo.app.ai.toJson
import com.lodo.app.core.NewsPlan
import com.lodo.app.core.TaskStatus
import com.lodo.app.data.AgentKind
import com.lodo.app.data.AgentMessageEntity
import com.lodo.app.data.CountdownEditRecord
import com.lodo.app.data.LibraryEditRecord
import com.lodo.app.data.TaskEntity
import com.lodo.app.data.TripEditRecord
import com.lodo.app.data.TripPlanRecord
import com.lodo.app.data.taskFromJson
import com.lodo.app.data.toJson
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.data.tripPlanFromJson
import com.lodo.app.ui.L
import com.lodo.app.ui.localizedParsedTaskCaption
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * AI 助手:单一持续对话 + 路由(对应 iOS AgentHostView + AgentHostView+Routing)。
 * 侧栏里的 AI 页和各页底部「问问 AI」拉起的那一层共用同一个实例(Activity 作用域)。
 *
 * 路由的取舍与 iOS 一致:单条新建/修改直接落库(卡片上可撤销/取消),批量或含完成/删除的
 * 进确认卡;倒数日/资产/订阅直接执行带撤销;行程规划先给卡片、点「写入行程」才落库,
 * 「记录」类直接写;偏好与顺带记录静默落盘;关键信息缺失时出提问卡。
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AgentViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp

    /** 消息窗口:倒序取最近 N 条再翻回正序,顶上「载入更早的对话」加一页。 */
    private val window = MutableStateFlow(60)
    /** null = 还没从库里读出来(这时不显示空态的问候,免得闪一下)。 */
    val messages = window.flatMapLatest { n -> app.agent.observeRecent(n).map<List<AgentMessageEntity>, List<AgentMessageEntity>?> { it.reversed() } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun loadEarlier() { window.value += 60 }

    var busy by mutableStateOf(false)
        private set
    /** 进行中的提示(思考中/联网搜索中…)。 */
    var status by mutableStateOf<String?>(null)
        private set
    /** 流式输出中的 answer 正文(全文);null = 没有在流的回答(同 iOS 的流式预览)。 */
    var streamText by mutableStateOf<String?>(null)
        private set
    /** 推理模型先吐的思考过程的尾巴,接在「思考中…」后面。 */
    private val reasoning = StringBuilder()
    var draft by mutableStateOf("")
    /** 页面焦点:从哪一页的「问问 AI」拉起,AI 页本身为 null。 */
    var focus by mutableStateOf<AgentFocus?>(null)
    /** 请求输入框获取焦点的信号(每次 +1)。 */
    var focusRequest by mutableIntStateOf(0)

    private var job: Job? = null

    /** 确认卡对应的待执行操作(只在内存里;确认卡只在最新一条可点)。 */
    private val pendingActions = mutableMapOf<String, List<AIAction>>()

    /** 最近一批可撤销的操作(批量执行 / 单条修改),只认最新一条消息。 */
    private var lastUndo: Pair<String, List<UndoOp>>? = null

    sealed interface UndoOp {
        data class Created(val uuid: String) : UndoOp
        data class Updated(val before: TaskEntity) : UndoOp
        data class Completed(val before: TaskEntity, val historyUuid: String?) : UndoOp
        data class Deleted(val before: TaskEntity) : UndoOp
        data class Memorized(val uuid: String) : UndoOp
    }

    /** 待发送的附件(同 iOS PendingAttachment):照片/文件已经在端上转成文字,记忆库条目取它的内容。 */
    data class PendingAttachment(
        val id: String = java.util.UUID.randomUUID().toString(),
        val name: String,
        val text: String = "",
        val extracting: Boolean = false,
        val isImage: Boolean = false,
    )
    val attachments = androidx.compose.runtime.mutableStateListOf<PendingAttachment>()

    private fun addExtracting(name: String, isImage: Boolean, extract: suspend () -> String) {
        val pending = PendingAttachment(name = name, extracting = true, isImage = isImage)
        attachments += pending
        viewModelScope.launch {
            val text = runCatching { extract() }.getOrDefault("")
            val i = attachments.indexOfFirst { it.id == pending.id }
            if (i >= 0) attachments[i] = pending.copy(text = text, extracting = false)
        }
    }

    fun addImage(uri: android.net.Uri) = addExtracting(
        com.lodo.app.data.AttachmentExtractor.displayName(app, uri), true) { com.lodo.app.data.AttachmentExtractor.image(app, uri) }

    fun addFile(uri: android.net.Uri) = addExtracting(
        com.lodo.app.data.AttachmentExtractor.displayName(app, uri), false) { com.lodo.app.data.AttachmentExtractor.file(app, uri) }

    fun addMemories(items: List<com.lodo.app.data.MemoryEntity>) {
        items.filter { m -> attachments.none { it.id == m.uuid } }.forEach { m ->
            attachments += PendingAttachment(
                id = m.uuid, name = m.title,
                text = listOf(m.summary, m.sourceText).filter { it.isNotBlank() }.joinToString("\n").take(com.lodo.app.data.AttachmentExtractor.MAX_CHARS),
            )
        }
    }

    fun removeAttachment(id: String) { attachments.removeAll { it.id == id } }

    val canSend: Boolean get() = !busy && (draft.isNotBlank() || attachments.isNotEmpty()) && attachments.none { it.extracting }

    fun send(text: String = draft) {
        val trimmed = text.trim()
        if (busy || (trimmed.isEmpty() && attachments.isEmpty()) || attachments.any { it.extracting }) return
        val sending = attachments.toList()
        attachments.clear()
        draft = ""
        // 附件文字拼在这句话后面发出去(同 iOS):一个字都没认出来时说明白,模型才不会以为自己看得见图。
        var outgoing = trimmed
        for (a in sending) {
            val body = a.text.trim()
            outgoing += if (body.isEmpty()) "\n\n[附件:${a.name},没有识别出文字]" else "\n\n[附件:${a.name}]\n$body"
        }
        job = viewModelScope.launch {
            val payload = if (sending.isEmpty()) null else org.json.JSONObject().put("attachments", org.json.JSONArray(sending.map { it.name }))
            val userMsg = app.agent.insert("user", AgentKind.USER, trimmed, payload)
            run(outgoing, userMsg.uuid)
        }
    }

    fun cancel() {
        job?.cancel()
        busy = false
        status = null
        viewModelScope.launch { app.agent.insert("assistant", AgentKind.TEXT, L("已取消这次操作。", "Cancelled.")) }
    }

    private suspend fun run(text: String, excludeUuid: String?) {
        busy = true
        status = L("思考中…", "Thinking…")
        try {
            route(text, excludeUuid)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            app.agent.insert("assistant", AgentKind.ERROR, e.message ?: L("出错了", "Something went wrong"))
        } finally {
            busy = false
            status = null
            streamText = null
            reasoning.setLength(0)
        }
        runCatching { app.agent.compactIfNeeded(app.settings.aiConfig()) }
    }

    private fun isUndoCommand(text: String) =
        text.trim().lowercase() in setOf("撤销", "撤销上一步", "撤销上一条", "撤回", "撤回上一步", "undo")

    private suspend fun context(excludeUuid: String?): CommandContext {
        val settings = app.settings.snapshot()
        val pending = app.database.taskDao().pending().sortedBy { it.nextRemindAtMillis }
        val trips = app.travel.allTrips()
        val feeds = app.news.feeds()
        val countdowns = app.countdowns.all()
        val healthOn = settings.healthEnabled && app.health.isAvailable
        return CommandContext(
            tasks = pending.map { it.uuid to it.toParsedTask() },
            caps = CommandCapabilities(
                memory = true, webSearch = app.settings.webSearchConfigured(), health = healthOn,
                travel = trips.isNotEmpty(), tripPlan = true, news = feeds.isNotEmpty(),
                countdown = true, assets = true, feeds = true,
            ),
            countdowns = countdowns.map {
                CountdownPromptEntry(it.uuid, it.title, it.startMillis.toLocalDateTime(), it.endMillis?.toLocalDateTime(),
                    it.allDay, it.showInWidget, it.archived, it.startReminderList, it.endReminderList)
            },
            assets = app.library.assetEntries(),
            feeds = feeds.map { FeedPromptEntry(it.uuid, it.title, it.url, it.kind, it.enabled) },
            pageFocus = focus?.promptBlock,
            history = app.agent.history(excludeUuid),
            summary = app.agent.summary()?.text,
            preferences = app.agent.preferences(),
            existingProjects = pending.map { it.project }.filter { it.isNotBlank() }.distinct(),
        )
    }

    /** 一轮的边界(同 iOS route 里的 beginTurn + defer endTurn):ReAct 最多 3 次请求的用量累计到一起。 */
    private suspend fun route(text: String, excludeUuid: String?) {
        com.lodo.app.ai.AIUsageMonitor.beginTurn()
        try { routeTurn(text, excludeUuid) } finally { com.lodo.app.ai.AIUsageMonitor.endTurn() }
    }

    private suspend fun routeTurn(text: String, excludeUuid: String?) {
        if (isUndoCommand(text)) {
            app.agent.insert("assistant", AgentKind.TEXT, undoLatest())
            return
        }
        val config = app.settings.aiConfig()
        var ctx = context(excludeUuid)
        repeat(3) {
            reasoning.setLength(0)
            val result = DeepSeekClient.command(
                config, text, ctx,
                onStream = { streamText = it.ifEmpty { null } },
                onReasoning = { delta ->
                    synchronized(reasoning) {
                        reasoning.append(delta)
                        val tail = reasoning.toString().replace(Regex("\\s+"), " ").takeLast(40)
                        status = L("思考中…", "Thinking…") + " " + tail
                    }
                },
            )
            when (result) {
                is AICommandResult.Ask -> {
                    insertAsk(text, result.questions)
                    return
                }
                is AICommandResult.ToolCall -> {
                    status = toolStatus(result.tool)
                    val observation = runTool(result.tool)
                    ctx = ctx.copy(history = ctx.history + ("assistant" to observation))
                    status = L("思考中…", "Thinking…")
                }
                is AICommandResult.Actions -> {
                    handleActions(result.actions, text)
                    return
                }
            }
        }
        throw IllegalStateException(L("AI 调用工具次数过多,请换个说法再试。", "Too many tool calls, please rephrase."))
    }

    private fun toolStatus(tool: AITool) = when (tool) {
        is AITool.WebSearch -> L("联网搜索:", "Searching: ") + tool.query
        is AITool.WebFetch -> L("读取链接…", "Reading link…")
        is AITool.SearchMemory -> L("查找记忆…", "Searching memories…")
        is AITool.ReadHealth -> L("读取健康数据…", "Reading health data…")
        is AITool.ReadTrip -> L("读取行程…", "Reading trip…")
        is AITool.SearchNews -> L("查找订阅文章…", "Searching your feeds…")
        is AITool.LoadSkill -> L("加载 skill:${tool.name}…", "Loading skill ${tool.name}…")
    }

    /** 执行只读工具,结果作为一条历史喂回模型(同 iOS 的 ReAct 历史写法)。 */
    private suspend fun runTool(tool: AITool): String = when (tool) {
        is AITool.WebSearch -> {
            val observation = try {
                val key = app.settings.apiKey(WebSearchClient.PROVIDER_NAME).orEmpty()
                val results = WebSearchClient.search(key, tool.query)
                if (results.isEmpty()) "没有搜到相关结果"
                else results.joinToString("\n\n") { "「${it.title}」${it.snippet}\n来源:${it.url}" }
            } catch (e: Exception) { "联网搜索失败:${e.message}" }
            "[联网搜索“${tool.query}”的结果]\n$observation"
        }
        is AITool.WebFetch -> {
            val fetched = runCatching { WebSearchClient.fetchUrl(tool.url) }.getOrElse { "抓取链接失败:${it.message}" }
            "[抓取链接 ${tool.url} 的内容]\n" + fetched.ifEmpty { "抓取失败或页面无正文内容" }
        }
        is AITool.SearchMemory -> {
            val c = app.memoryRepository.retrieveCandidates(tool.query)
            "[记忆检索“${tool.query}”的结果]\n" + if (c.isEmpty()) "没有找到相关记忆内容" else c.joinToString("\n") {
                (if (it.uuid.startsWith("task:")) "[待办历史] " else "") + "「${it.title}」${it.excerpt}"
            }
        }
        is AITool.ReadHealth -> {
            val report = app.health.report(tool.days)
            "[最近 ${tool.days} 天的健康数据]\n" + report.promptSummary().ifEmpty { "没有可用的健康数据(未授权或没有记录)。" }
        }
        is AITool.ReadTrip -> "[读取行程]\n" + app.travel.readTrip(tool.name, includeIds = true)
        // 只有已启用的外部 skill 取得到;取不到如实告诉模型,别让它凭空编内容(同 iOS)。
        is AITool.LoadSkill -> "[skill「${tool.name}」的内容]\n" + (com.lodo.app.ai.AgentSkillStore.loadCustomBody(tool.name) ?: "没有这个 skill")
        is AITool.SearchNews -> {
            val hits = NewsPlan.search(tool.query, app.news.lines(enabledOnly = false))
            "[订阅文章检索“${tool.query}”的结果]\n" + if (hits.isEmpty()) "订阅里没有相关文章" else NewsPlan.promptLines(hits, includeLink = true)
        }
    }

    private suspend fun handleActions(all: List<AIAction>, userText: String) {
        val config = app.settings.aiConfig()
        var actions = all
        // 偏好、顺带记录:先摘出来静默落盘,不进确认页、不参与撤销(同 iOS route())。
        actions.filterIsInstance<AIAction.RememberPreference>().forEach { app.agent.appendPreference(it.text, config) }
        actions.filterIsInstance<AIAction.AutoMemorize>().forEach { auto ->
            app.memoryRepository.saveAutoMemory(auto.title, auto.text)?.let { item ->
                insertMemoryResult(item.uuid, item.title, item.summary, auto = true)
            }
        }
        actions = actions.filterNot { it is AIAction.RememberPreference || it is AIAction.AutoMemorize }

        // 倒数日 / 资产 / 订阅:直接执行,各出一张带撤销的结果卡。
        val countdownOps = actions.filterIsInstance<AIAction.Countdown>().map { it.op }
        if (countdownOps.isNotEmpty()) {
            val record = app.countdowns.apply(countdownOps)
            app.agent.insert("assistant", AgentKind.COUNTDOWN_EDIT, record.transcript, JSONObject(record.toJson()))
        }
        val assetOps = actions.filterIsInstance<AIAction.Asset>().map { it.op }
        val feedOps = actions.filterIsInstance<AIAction.Feed>().map { it.op }
        if (assetOps.isNotEmpty() || feedOps.isNotEmpty()) {
            status = L("处理中…", "Working…")
            val record = app.library.apply(assetOps, feedOps)
            app.agent.insert("assistant", AgentKind.LIBRARY_EDIT, record.transcript, JSONObject(record.toJson()))
        }
        actions = actions.filterNot { it is AIAction.Countdown || it is AIAction.Asset || it is AIAction.Feed }
        if (actions.isEmpty()) {
            if (all.all { it is AIAction.RememberPreference }) {
                app.agent.insert("assistant", AgentKind.TEXT, L("好的,记住了。", "Got it, I'll remember that."))
            }
            return
        }

        if (actions.size == 1) {
            when (val a = actions[0]) {
                is AIAction.Create -> {
                    val created = app.repository.saveNew(a.task)
                    insertTaskResult(created, mode = "created")
                    return
                }
                is AIAction.Update -> {
                    val before = app.repository.current(a.uuid)
                    if (before == null || before.statusEnum != TaskStatus.PENDING) {
                        throw IllegalStateException(L("找不到要修改的任务", "Task not found"))
                    }
                    app.repository.applyEdit(a.uuid, a.task)
                    val after = app.repository.current(a.uuid) ?: before
                    val msg = insertTaskResult(after, mode = "updated")
                    lastUndo = msg.uuid to listOf(UndoOp.Updated(before))
                    return
                }
                is AIAction.Answer -> {
                    app.agent.insert("assistant", AgentKind.ANSWER, a.text)
                    streamText = null
                    return
                }
                is AIAction.Memorize -> {
                    status = L("整理收藏…", "Organizing…")
                    val item = app.memoryRepository.saveText(config, a.text)
                    insertMemoryResult(item.uuid, item.title, item.summary, auto = false)
                    return
                }
                is AIAction.SuggestMemorize -> {
                    app.agent.insert("assistant", AgentKind.SUGGEST_MEMORIZE, a.text, JSONObject().put("text", a.text).put("saved", false))
                    return
                }
                is AIAction.AskMemory -> {
                    val candidates = app.memoryRepository.retrieveCandidates(a.question)
                    val answer = if (candidates.isEmpty()) L("还没有相关的收藏。", "No matching memories yet.")
                    else DeepSeekClient.askMemory(config, a.question, candidates).first
                    app.agent.insert("assistant", AgentKind.ANSWER, answer)
                    return
                }
                is AIAction.PlanTrip -> {
                    val payload = JSONObject().put("plan", a.plan.toJson())
                    val summary = a.plan.items.joinToString(";") { it.title }
                    if (a.plan.recorded) {
                        val record = app.travel.applyPlan(a.plan)
                        payload.put("record", record.toJson())
                    }
                    app.agent.insert("assistant", AgentKind.TRIP_PLAN,
                        "行程规划「${a.plan.tripTitle}」${a.plan.startDate} 至 ${a.plan.endDate}:$summary" +
                            if (a.plan.recorded) "(已写入)" else "", payload)
                    return
                }
                is AIAction.EditTrip -> {
                    val record = app.travel.applyEdit(a.edit)
                    if (!record.hasChanges) {
                        app.agent.insert("assistant", AgentKind.TEXT,
                            L("行程没有改动:", "Nothing changed: ") + record.skipped.joinToString("、"))
                    } else {
                        app.agent.insert("assistant", AgentKind.TRIP_EDIT, record.transcript, JSONObject(record.toJson()))
                    }
                    return
                }
                else -> {}
            }
        }
        // 批量 / 完成 / 删除:进确认卡。
        val lines = actions.map(::describe)
        val msg = app.agent.insert("assistant", AgentKind.CONFIRM, "待确认:" + lines.joinToString(";"),
            JSONObject().put("lines", JSONArray(lines)).put("state", "pending"))
        pendingActions[msg.uuid] = actions
    }

    private fun describe(a: AIAction): String {
        val lang = com.lodo.app.core.CurrentLang.value
        fun title(uuid: String) = kotlinx.coroutines.runBlocking { app.repository.current(uuid)?.title } ?: L("(未知任务)", "(unknown task)")
        return when (a) {
            is AIAction.Create -> L("新建:", "Create: ") + a.task.title + " · " + localizedParsedTaskCaption(a.task, lang)
            is AIAction.Update -> L("修改:", "Update: ") + a.task.title + " · " + localizedParsedTaskCaption(a.task, lang)
            is AIAction.Complete -> L("完成:", "Complete: ") + title(a.uuid)
            is AIAction.Delete -> L("删除:", "Delete: ") + title(a.uuid)
            is AIAction.Memorize -> L("收藏:", "Save: ") + a.text
            else -> a.toString()
        }
    }

    private suspend fun insertTaskResult(task: TaskEntity, mode: String): AgentMessageEntity {
        val header = if (mode == "created") L("已新建", "Created") else L("已修改", "Updated")
        val payload = JSONObject().put("mode", mode).put("task", task.toJson()).put("removed", false)
        return app.agent.insert("assistant", AgentKind.TASK_RESULT, "$header:${task.title}(${task.nextRemindAt})", payload)
    }

    private suspend fun insertMemoryResult(uuid: String, title: String, summary: String, auto: Boolean) {
        app.agent.insert("assistant", AgentKind.MEMORY_RESULT,
            (if (auto) "已顺带记下:" else "已收藏:") + title,
            JSONObject().put("uuid", uuid).put("title", title).put("summary", summary).put("auto", auto).put("removed", false))
    }

    private suspend fun insertAsk(originalText: String, questions: List<AskQuestion>) {
        val content = "提问:" + questions.joinToString(";") { it.question }
        app.agent.insert("assistant", AgentKind.ASK, content,
            JSONObject().put("original", originalText).put("questions", JSONArray(questions.map { it.toJson() })).put("state", "pending"))
    }

    // ---------------- 卡片上的操作 ----------------

    /** 提问卡答完:选择静默随下一轮请求回传(不冒用户气泡),卡片原地变只读记录。 */
    fun answerAsk(msg: AgentMessageEntity, answers: List<Pair<String, String>>) {
        if (busy) return
        val payload = JSONObject(msg.payloadJson ?: return)
        val original = payload.optString("original")
        payload.put("state", "answered").put("answers", JSONArray(answers.map { JSONObject().put("q", it.first).put("a", it.second) }))
        job = viewModelScope.launch {
            app.agent.update(msg.copy(payloadJson = payload.toString(),
                content = msg.content + "\n用户的选择:" + answers.joinToString(";") { "${it.first} → ${it.second}" }))
            val follow = original + "\n补充:" + answers.joinToString(";") { "${it.first}:${it.second}" }
            run(follow, null)
        }
    }

    fun cancelAsk(msg: AgentMessageEntity) = viewModelScope.launch {
        val payload = JSONObject(msg.payloadJson ?: return@launch).put("state", "cancelled")
        app.agent.update(msg.copy(payloadJson = payload.toString()))
    }

    fun confirm(msg: AgentMessageEntity) = viewModelScope.launch {
        val actions = pendingActions.remove(msg.uuid) ?: return@launch
        app.agent.update(msg.copy(payloadJson = JSONObject(msg.payloadJson ?: "{}").put("state", "done").toString()))
        var missing = 0
        val ops = mutableListOf<UndoOp>()
        for (a in actions) {
            when (a) {
                is AIAction.Create -> ops += UndoOp.Created(app.repository.saveNew(a.task).uuid)
                is AIAction.Update -> {
                    val before = app.repository.current(a.uuid)
                    if (before != null && before.statusEnum == TaskStatus.PENDING) {
                        app.repository.applyEdit(a.uuid, a.task); ops += UndoOp.Updated(before)
                    } else missing++
                }
                is AIAction.Complete -> {
                    val before = app.repository.current(a.uuid)
                    if (before != null && before.statusEnum == TaskStatus.PENDING) {
                        ops += UndoOp.Completed(before, app.repository.complete(a.uuid)?.uuid)
                    } else missing++
                }
                is AIAction.Delete -> {
                    val before = app.repository.current(a.uuid)
                    if (before != null) { app.repository.delete(a.uuid); ops += UndoOp.Deleted(before) } else missing++
                }
                is AIAction.Memorize -> ops += UndoOp.Memorized(app.memoryRepository.saveText(app.settings.aiConfig(), a.text).uuid)
                else -> {}
            }
        }
        val lines = JSONObject(msg.payloadJson ?: "{}").optJSONArray("lines") ?: JSONArray()
        val text = L("已完成执行", "Done") + (if (missing > 0) L("($missing 项已不存在,未执行)", " ($missing skipped — no longer exists)") else "")
        val result = app.agent.insert("assistant", AgentKind.BATCH_RESULT, text + ":" + (0 until lines.length()).joinToString(";") { lines.optString(it) },
            JSONObject().put("lines", lines).put("missing", missing).put("undone", false))
        if (ops.isNotEmpty()) lastUndo = result.uuid to ops
    }

    fun cancelConfirm(msg: AgentMessageEntity) = viewModelScope.launch {
        pendingActions.remove(msg.uuid)
        app.agent.update(msg.copy(payloadJson = JSONObject(msg.payloadJson ?: "{}").put("state", "cancelled").toString()))
    }

    fun canConfirm(msg: AgentMessageEntity) = pendingActions.containsKey(msg.uuid)
    fun canUndo(msg: AgentMessageEntity) = lastUndo?.first == msg.uuid

    /** 卡片上的撤销 / 文字"撤销":撤最近一批(批量执行或单条修改)。 */
    fun undo(msg: AgentMessageEntity) = viewModelScope.launch {
        if (lastUndo?.first != msg.uuid) return@launch
        val text = undoLatest()
        app.agent.update(msg.copy(payloadJson = JSONObject(msg.payloadJson ?: "{}").put("undone", true).toString(),
            content = msg.content + "(已撤销)"))
        app.agent.insert("assistant", AgentKind.TEXT, text)
    }

    private suspend fun undoLatest(): String {
        val (_, ops) = lastUndo ?: return L("没有可以撤销的操作。", "Nothing to undo.")
        lastUndo = null
        var missing = 0
        for (op in ops.reversed()) {
            when (op) {
                is UndoOp.Created -> if (!app.repository.removeIfExists(op.uuid)) missing++
                is UndoOp.Updated -> if (app.repository.exists(op.before.uuid)) app.repository.restoreSnapshot(op.before) else missing++
                is UndoOp.Completed -> {
                    if (app.repository.exists(op.before.uuid)) app.repository.restoreSnapshot(op.before) else missing++
                    op.historyUuid?.let { app.repository.removeIfExists(it) }
                }
                is UndoOp.Deleted -> app.repository.restoreSnapshot(op.before)
                is UndoOp.Memorized -> app.memoryRepository.delete(op.uuid)
            }
        }
        return if (missing > 0) L("已撤销,$missing 项已不存在。", "Undone; $missing item(s) no longer exist.")
        else L("已撤销上一步操作。", "Undone.")
    }

    /** 新建结果卡上的开关:删掉 ↔ 按同一份快照重建(uuid 换新的),不限最新一条(同 iOS)。 */
    fun toggleCreated(msg: AgentMessageEntity) = viewModelScope.launch {
        val payload = JSONObject(msg.payloadJson ?: return@launch)
        val task = taskFromJson(payload.getJSONObject("task"))
        if (!payload.optBoolean("removed")) {
            app.repository.removeIfExists(task.uuid)
            payload.put("removed", true)
        } else {
            val recreated = app.repository.saveNew(task.toParsedTask())
            payload.put("task", recreated.toJson()).put("removed", false)
        }
        app.agent.update(msg.copy(payloadJson = payload.toString()))
    }

    /** 收藏/顺带记录卡上的 ✕:删条目,卡片原地改写成「已取消收藏」。 */
    fun removeMemory(msg: AgentMessageEntity) = viewModelScope.launch {
        val payload = JSONObject(msg.payloadJson ?: return@launch)
        app.memoryRepository.delete(payload.getString("uuid"))
        payload.put("removed", true)
        app.agent.update(msg.copy(payloadJson = payload.toString(), content = L("已取消收藏。", "Removed.")))
    }

    fun saveSuggestion(msg: AgentMessageEntity) = viewModelScope.launch {
        val payload = JSONObject(msg.payloadJson ?: return@launch)
        if (payload.optBoolean("saved")) return@launch
        payload.put("saved", true)
        app.agent.update(msg.copy(payloadJson = payload.toString()))
        app.memoryRepository.saveText(app.settings.aiConfig(), payload.getString("text"))
    }

    fun toggleCountdown(msg: AgentMessageEntity) = viewModelScope.launch {
        val record = CountdownEditRecord.decode(msg.payloadJson) ?: return@launch
        if (!record.reverted) {
            app.countdowns.revert(record)
        } else {
            // 重新执行:按快照写回"改完之后"的样子。
            record.created.forEach { app.countdowns.save(it) }
            record.updatedAfter.forEach { app.countdowns.save(it) }
            record.deleted.forEach { app.countdowns.delete(it.uuid) }
        }
        val next = record.copy(reverted = !record.reverted)
        app.agent.update(msg.copy(payloadJson = next.toJson(), content = next.transcript))
    }

    fun toggleLibrary(msg: AgentMessageEntity) = viewModelScope.launch {
        val record = LibraryEditRecord.decode(msg.payloadJson) ?: return@launch
        if (record.reverted) return@launch
        app.library.revert(record)
        val next = record.copy(reverted = true)
        app.agent.update(msg.copy(payloadJson = next.toJson(), content = next.transcript))
    }

    fun toggleTripEdit(msg: AgentMessageEntity) = viewModelScope.launch {
        val record = TripEditRecord.decode(msg.payloadJson) ?: return@launch
        if (record.reverted) return@launch
        app.travel.revertEdit(record)
        val next = record.copy(reverted = true)
        app.agent.update(msg.copy(payloadJson = next.toJson(), content = next.transcript))
    }

    /** 行程规划卡:写入 / 撤销 / 重新写入。 */
    fun toggleTripPlan(msg: AgentMessageEntity) = viewModelScope.launch {
        val payload = JSONObject(msg.payloadJson ?: return@launch)
        val plan = tripPlanFromJson(payload.getJSONObject("plan"))
        val record = TripPlanRecord.from(payload.optJSONObject("record"))
        if (record == null) {
            val r = app.travel.applyPlan(plan)
            payload.put("record", r.toJson())
            app.agent.update(msg.copy(payloadJson = payload.toString(), content = msg.content.removeSuffix("(已撤销)") + "(已写入)"))
        } else {
            app.travel.revertPlan(record)
            payload.remove("record")
            payload.put("reverted", true)
            app.agent.update(msg.copy(payloadJson = payload.toString(), content = msg.content.removeSuffix("(已写入)") + "(已撤销)"))
        }
    }

    /** 长按气泡「修改」:截断到这条之前,把原话放回输入框(同 iOS);被删掉的已压进摘要的话重置摘要。 */
    fun editFrom(msg: AgentMessageEntity) = viewModelScope.launch {
        if (busy) return@launch
        app.database.agentMessageDao().deleteFrom(msg.createdAtMillis)
        app.agent.summary()?.let { if (it.watermarkMillis >= msg.createdAtMillis) app.agent.resetSummary() }
        draft = msg.content
        focusRequest++
    }

    fun clearConversation() = viewModelScope.launch {
        app.agent.clear()
        pendingActions.clear()
        lastUndo = null
    }
}
