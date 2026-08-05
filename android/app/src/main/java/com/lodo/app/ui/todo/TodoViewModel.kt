package com.lodo.app.ui.todo

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.ai.AIAction
import com.lodo.app.ai.AICommandResult
import com.lodo.app.ai.AITool
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.DeepSeekException
import com.lodo.app.ai.DurationMemory
import com.lodo.app.ai.ParsedTask
import com.lodo.app.ai.WebSearchClient
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TaskStatus
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.TaskEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalDateTime

/** 底部弹层模式,对应 iOS SheetMode。 */
sealed interface SheetMode {
    /** 快速添加页(AI 输入 + 手动表单)。 */
    data object Add : SheetMode
    /** 全局 agent(一句话新增/修改/完成/删除,可带预填);autoStart 为 true 时
     * 弹出后自动拉起系统语音识别(FAB 触发时为 true,顶栏 ✨ 按钮为 false)。 */
    data class Agent(val prefill: String? = null, val autoStart: Boolean = false) : SheetMode
    data class Create(val parsed: ParsedTask?) : SheetMode
    data class Edit(val task: TaskEntity, val parsed: ParsedTask? = null) : SheetMode
}

/** 全局 agent 一次解析后的回应形态,对应 iOS AgentReply。 */
sealed interface AgentReply {
    /** 已直达表单(单条新建/修改),agent 页无事可做。 */
    data object Routed : AgentReply
    /** 需要确认的操作清单(批量或含完成/删除),元素为中文描述。 */
    data class Confirm(val lines: List<String>) : AgentReply
    /** 关键信息缺失,反问 + 候选补充。 */
    data class Clarify(val question: String, val options: List<String>) : AgentReply
    /** 纯文字回应:撤销结果、联网搜索后直接回答的一般性问题。 */
    data class Message(val text: String) : AgentReply
}

/** agent 批量执行(performPendingActions)后留下的撤销记录,一条操作一个 case;
 * 直接拿 TaskEntity 当"改回原样"的载体(Room 实体本来就是展平字段的 data
 * class,不用像 iOS 那样另起一套快照结构)。只保留最近一批,执行新的批量
 * 操作或用掉一次撤销都会清空。Android 的 AI 助手弹层是一次性的(没有 iOS 那种
 * 持久多 thread 对话),不存在"跨 thread 撤错批次"的问题,不需要额外隔离。 */
sealed interface UndoOp {
    data class Created(val uuid: String) : UndoOp
    data class Updated(val before: TaskEntity) : UndoOp
    /** insertedHistoryUuid:重复事项完成一次时插入的历史记录,撤销要连它一起删掉。 */
    data class Completed(val before: TaskEntity, val insertedHistoryUuid: String?) : UndoOp
    data class Deleted(val before: TaskEntity) : UndoOp
}

data class TodoUiState(
    val due: List<TaskEntity> = emptyList(),
    val pending: List<TaskEntity> = emptyList(),
    val done: List<TaskEntity> = emptyList(),
    val snoozeMinutes: Int = 15,
    val allDayTime: String = "09:00",
    val hapticsEnabled: Boolean = true,
    val agentAutoRecordOnOpen: Boolean = true,
    val agentSilenceTimeoutSeconds: Int = 3,
    /** 通知权限被拒绝,待办列表顶部显示提示横幅。 */
    val notificationPermissionDenied: Boolean = false,
)

class TodoViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp

    /** 下一次需要唤醒的间隔(毫秒),由 combine 按最近到期时间更新;上限 10 分钟。 */
    @Volatile
    private var nextWakeDelayMillis = 10_000L

    /** 按需心跳:睡到最近一个到期时刻再刷新,替代固定 10 秒轮询。 */
    private val ticker = flow {
        while (true) {
            emit(Unit)
            delay(nextWakeDelayMillis)
        }
    }

    val uiState = combine(
        app.database.taskDao().observePending(), app.database.taskDao().observeDone(),
        ticker, app.settings.settings,
    ) { pendingTasks, doneTasks, _, settings ->
        val now = LocalDateTime.now()
        // 计算下一次唤醒:最近一个未到期事项,否则 10 分钟兜底
        val nowMillis = System.currentTimeMillis()
        nextWakeDelayMillis = pendingTasks
            .filter { it.nextRemindAtMillis > nowMillis }
            .minOfOrNull { it.nextRemindAtMillis - nowMillis + 1_000 }
            ?.coerceIn(1_000L, 600_000L) ?: 600_000L
        TodoUiState(
            due = pendingTasks.filter { it.toData().isDue(now) },
            pending = pendingTasks,
            done = doneTasks,
            snoozeMinutes = settings.snoozeMinutes,
            allDayTime = settings.allDayTime,
            hapticsEnabled = settings.hapticsEnabled,
            agentAutoRecordOnOpen = settings.agentAutoRecordOnOpen,
            agentSilenceTimeoutSeconds = settings.agentSilenceTimeoutSeconds,
            notificationPermissionDenied = settings.notificationPermissionDenied,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), TodoUiState())

    var sheet by mutableStateOf<SheetMode?>(null)

    /** 日期条选中的日期,默认今天。 */
    var selectedDate by mutableStateOf(LocalDate.now())

    /** 完成后询问实际耗时的轻量条(队列,连续完成不互相覆盖):(标题, 计划分钟)。 */
    var askDurationQueue by mutableStateOf<List<Pair<String, Int>>>(emptyList())
        private set

    /** 到期卡改期:请求中的事项 uuid / 已返回的候选 / 错误。 */
    var rescheduleLoadingUuid by mutableStateOf<String?>(null)
        private set
    var reschedule by mutableStateOf<Pair<String, List<Pair<String, LocalDateTime>>>?>(null)
        private set
    var rescheduleError by mutableStateOf<String?>(null)
        private set
    private var rescheduleJob: kotlinx.coroutines.Job? = null

    /** agent 解析出、等待用户确认的批量操作。 */
    private var pendingActions: List<AIAction> = emptyList()

    /** 上一批 agent 执行完的操作,供"撤销"用(见 undoLastBatch)。 */
    private var lastUndo: List<UndoOp>? = null

    /** lastUndo 对应的"批次编号",每批批量执行自增一次。Snackbar 的撤销按钮
     * 带着自己那批的编号调用撤销——如果 Snackbar A 还没消失、Snackbar B 又
     * 弹出来(lastUndo 已经被 B 那批覆盖),这时点 A 的撤销不能真的把 B 那批
     * 撤了,必须先核对编号对不对,不对就拒绝(而不是撤销一个用户根本没看到、
     * 也没确认过的批次)。文字指令"撤销"不受这个限制,永远撤最新一批。 */
    private var lastUndoToken: Long = 0L

    /** 批量操作执行完、有东西可撤销时触发一次(带上这批的编号),UI 据此弹
     * 一条带"撤销"按钮的 Snackbar(Android 没有 iOS 那种持久聊天气泡,撤销
     * 入口走系统 Snackbar 更符合平台习惯)。 */
    private val _undoAvailableEvents = MutableSharedFlow<Long>(extraBufferCapacity = 1)
    val undoAvailableEvents: SharedFlow<Long> = _undoAvailableEvents.asSharedFlow()

    // ---- 全局 agent ----

    /** 要求整句话就是这几个固定短语之一,不做"包含"匹配,避免误伤正常事项标题。 */
    private fun isUndoCommand(text: String): Boolean {
        val trimmed = text.trim().lowercase()
        return trimmed in setOf("撤销", "撤销上一步", "撤销上一条", "撤回", "撤回上一步", "undo")
    }

    /**
     * agent 总入口:带上当前待办列表,把一句话解析成操作。
     * 单条新建/修改直达表单;批量或含完成/删除的进确认清单;信息缺失透传反问;
     * 单条 answer(联网搜索/一般性问题)直接展示。
     *
     * ReAct 循环:模型如果先要联网搜索才能给最终答案,会先返回一个 ToolCall
     * (只读、不落库),执行完把结果拼回原话再问一轮,最多 3 轮——不能无限转,
     * 也不允许写操作在这个循环里未经确认就被模型自己执行。Android 没有持久
     * 对话历史,搜索结果直接拼进下一轮的用户消息里,不单独维护一份 history。
     */
    suspend fun agentRoute(text: String): AgentReply {
        // 撤销走本地固定短语匹配,不进 AI 循环——这是确定性操作,交给模型理解
        // 反而多一次网络请求、多一种出错可能,不值得。
        if (isUndoCommand(text)) return AgentReply.Message(undoLastBatch())

        val context = uiState.value.pending.map { it.uuid to it.toParsedTask() }
        val webSearchEnabled = app.settings.webSearchConfigured()
        var currentText = text
        repeat(3) {
            when (val result = DeepSeekClient.command(
                app.settings.aiConfig(), currentText,
                context.sortedBy { it.second.remindAt }, webSearchEnabled,
            )) {
                is AICommandResult.Clarify -> return AgentReply.Clarify(result.question, result.options)
                is AICommandResult.ToolCall -> {
                    currentText = when (val tool = result.tool) {
                        is AITool.WebSearch -> {
                            val query = tool.query
                            val observation = try {
                                val key = app.settings.apiKey(WebSearchClient.PROVIDER_NAME).orEmpty()
                                val results = WebSearchClient.search(key, query)
                                if (results.isEmpty()) "没有搜到相关结果"
                                else results.joinToString("\n\n") {
                                    "「${it.title}」${it.snippet}\n来源:${it.url}"
                                }
                            } catch (e: Exception) {
                                "联网搜索失败:${e.message}"
                            }
                            "$text\n\n[联网搜索“$query”的结果]\n$observation\n\n" +
                                "请基于以上结果继续处理最初的请求。"
                        }
                        is AITool.WebFetch -> {
                            val url = tool.url
                            val observation = try {
                                val fetched = WebSearchClient.fetchUrl(url)
                                if (fetched.isEmpty()) "抓取失败或页面无正文内容" else fetched
                            } catch (e: Exception) {
                                "抓取链接失败:${e.message}"
                            }
                            "$text\n\n[抓取链接 $url 的内容]\n$observation\n\n" +
                                "请基于以上内容继续处理最初的请求。"
                        }
                    }
                }
                is AICommandResult.Actions -> {
                    val actions = result.actions
                    if (actions.size == 1) {
                        (actions[0] as? AIAction.Create)?.let {
                            sheet = SheetMode.Create(it.task)
                            return AgentReply.Routed
                        }
                        (actions[0] as? AIAction.Update)?.let { update ->
                            // 请求期间事项可能被完成/删除,用返回时的最新列表再匹配一次
                            val entity = uiState.value.pending.firstOrNull { it.uuid == update.uuid }
                                ?: throw DeepSeekException("无法解析:找不到要修改的事项")
                            sheet = SheetMode.Edit(entity, update.task)
                            return AgentReply.Routed
                        }
                        (actions[0] as? AIAction.Answer)?.let { return AgentReply.Message(it.text) }
                    }
                    pendingActions = actions
                    return AgentReply.Confirm(actions.map(::describe))
                }
            }
        }
        throw DeepSeekException("无法解析:多轮推理超过上限,换个说法试试")
    }

    private fun describe(action: AIAction): String = when (action) {
        is AIAction.Create -> {
            var caption = TimeFormat.format(action.task.remindAt)
            if (action.task.durationMinutes > 0) caption += " · ${action.task.durationMinutes} 分钟"
            "新建:${action.task.title}($caption)"
        }
        is AIAction.Update ->
            "修改:${action.task.title}(${TimeFormat.format(action.task.remindAt)})"
        is AIAction.Complete -> "完成:${titleOf(action.uuid) ?: "未知事项"}"
        is AIAction.Delete -> "删除:${titleOf(action.uuid) ?: "未知事项"}"
        // 防御性分支:agentRoute 已把单条 answer 短路直接返回,混合批次里理论上
        // 不会出现,兜底给出可读描述。
        is AIAction.Answer -> "回答:${action.text}"
    }

    private fun titleOf(uuid: String): String? =
        uiState.value.pending.firstOrNull { it.uuid == uuid }?.title

    /** 批量 agent 操作里有目标事项在确认期间被别处改动/删除时的提示。 */
    var actionsWarning by mutableStateOf<String?>(null)
        private set

    fun dismissActionsWarning() {
        actionsWarning = null
    }

    /** 执行确认后的批量操作,完毕关闭 agent。第一件事就是把 pendingActions 取走
     * 并清空——"确认执行"按钮没做防抖,快速重复点击会并发调用这个函数两次,
     * 立刻清空让第二次调用看到空列表直接结束,不会重复执行、也不会把 lastUndo
     * 搅乱。目标事项在等待确认期间可能已被通知按钮/Siri 并发改动或完成/删除,
     * 所以"存进 undoOps 的原样快照"和"存不存在"都要在真正执行前即时查一次
     * (TaskRepository.current),不能用弹层打开时那份可能已经过时的 UI 快照——
     * 否则撤销时会把并发发生的改动覆盖掉。 */
    fun performPendingActions() = viewModelScope.launch {
        val actionsToRun = pendingActions
        pendingActions = emptyList()
        var missingCount = 0
        val undoOps = mutableListOf<UndoOp>()
        for (action in actionsToRun) {
            when (action) {
                is AIAction.Create -> {
                    val created = app.repository.saveNew(action.task)
                    undoOps += UndoOp.Created(created.uuid)
                }
                is AIAction.Update -> {
                    val before = app.repository.current(action.uuid)
                    if (before != null && before.statusEnum == TaskStatus.PENDING) {
                        app.repository.applyEdit(action.uuid, action.task)
                        undoOps += UndoOp.Updated(before)
                    } else {
                        missingCount++
                    }
                }
                is AIAction.Complete -> {
                    val before = app.repository.current(action.uuid)
                    if (before != null && before.statusEnum == TaskStatus.PENDING) {
                        val history = app.repository.complete(action.uuid)
                        undoOps += UndoOp.Completed(before, history?.uuid)
                    } else {
                        missingCount++
                    }
                }
                is AIAction.Delete -> {
                    val before = app.repository.current(action.uuid)
                    if (before != null) {
                        app.repository.delete(action.uuid)
                        undoOps += UndoOp.Deleted(before)
                    } else {
                        missingCount++
                    }
                }
                // 防御性分支:agentRoute 已把单条 answer 短路直接返回,正常不会
                // 混进批次;没有可执行的落库动作。
                is AIAction.Answer -> {}
            }
        }
        sheet = null
        if (undoOps.isNotEmpty()) {
            lastUndo = undoOps
            val token = ++lastUndoToken
            _undoAvailableEvents.emit(token)
        }
        if (missingCount > 0) {
            actionsWarning = "有 $missingCount 项操作未执行:对应事项已不存在"
        }
    }

    /** agent 关闭时清掉未确认的操作,避免残留被后续误执行。 */
    fun clearPendingActions() {
        pendingActions = emptyList()
    }

    // ---- 撤销 ----

    /** 把 lastUndo 记录的上一批操作按相反方向改回去:新建 → 删除,修改/完成 →
     * 用之前的快照覆盖回去,删除 → 用快照重新插入(uuid 不变)。用完清空,
     * 只能撤销最近一批,不支持多级撤销栈。expectedToken 非 null 时(Snackbar
     * 按钮触发)要求和 lastUndoToken 对上,不对说明这批已经被后面新的一批
     * 覆盖,拒绝撤销——不然会在用户没看到、没确认过的情况下撤掉别的批次。
     * 文字指令"撤销"传 null,永远撤最新一批。 */
    private suspend fun undoLastBatch(expectedToken: Long? = null): String {
        if (expectedToken != null && expectedToken != lastUndoToken) {
            return "这批操作已经被后面的操作覆盖,无法撤销。"
        }
        val ops = lastUndo ?: return "没有可撤销的操作。"
        lastUndo = null
        var missingCount = 0
        for (op in ops.reversed()) {
            when (op) {
                is UndoOp.Created ->
                    if (!app.repository.removeIfExists(op.uuid)) missingCount++
                is UndoOp.Updated ->
                    if (app.repository.exists(op.before.uuid)) {
                        app.repository.restoreSnapshot(op.before)
                    } else {
                        missingCount++
                    }
                is UndoOp.Completed -> {
                    if (app.repository.exists(op.before.uuid)) {
                        app.repository.restoreSnapshot(op.before)
                    } else {
                        missingCount++
                    }
                    op.insertedHistoryUuid?.let { app.repository.removeIfExists(it) }
                }
                is UndoOp.Deleted -> app.repository.restoreSnapshot(op.before)
            }
        }
        return if (missingCount > 0) {
            "已撤销上一步操作($missingCount 项因事项已不存在无法撤销)。"
        } else {
            "已撤销上一步操作。"
        }
    }

    /** Snackbar"撤销"按钮直接调这个,带上那条 Snackbar 对应的批次编号
     * (核对是否已被后面的操作覆盖),不用再走一遍文字指令匹配。 */
    fun performUndo(token: Long) = viewModelScope.launch { undoLastBatch(expectedToken = token) }

    // ---- 快速添加页的 AI 解析(仅新建,回填手动表单) ----

    /** 解析一句话;无时长且有记忆时追加一次时长建议小请求,返回(字段, AI 建议的时长)。 */
    suspend fun addParse(text: String): Pair<ParsedTask, Int?> {
        val config = app.settings.aiConfig()
        var parsed = DeepSeekClient.parse(config, text)
        var suggested: Int? = null
        if (parsed.durationMinutes == 0) {
            DurationMemory.content(app)?.let { memory ->
                val minutes = runCatching {
                    DeepSeekClient.suggestDuration(config, text, parsed.title, memory)
                }.getOrDefault(0)
                if (minutes > 0) {
                    parsed = parsed.copy(durationMinutes = minutes)
                    suggested = minutes
                }
            }
        }
        return parsed to suggested
    }

    // ---- 完成 + 实际耗时采样 ----

    /** 完成;仅真正"完成一次"(非两阶段的"开始了")且命中采样时,询问实际用时。 */
    fun completeWithSampling(task: TaskEntity) = viewModelScope.launch {
        val isFinishing = !(task.phaseEnum == TaskPhase.START && task.durationMinutes > 0)
        app.repository.complete(task.uuid)
        if (isFinishing && task.durationMinutes > 0 &&
            DurationMemory.shouldAskActual(app, task.title, task.durationMinutes)
        ) {
            askDurationQueue = askDurationQueue + (task.title to task.durationMinutes)
        }
    }

    fun answerActualDuration(minutes: Int) {
        val (title, planned) = askDurationQueue.firstOrNull() ?: return
        askDurationQueue = askDurationQueue.drop(1)
        viewModelScope.launch {
            DurationMemory.recordActual(app, app.settings.aiConfig(), title, planned, minutes)
        }
    }

    fun skipActualDuration() {
        askDurationQueue = askDurationQueue.drop(1)
    }

    // ---- 到期卡改期 ----

    /** 通知"改期"按钮打开 App 后的路由消费:跳到事项所在日期并直接发起改期请求,
     * 等同于用户在到期卡片上手动点了一次"改期"。 */
    fun handleReschedule(uuid: String) {
        val task = uiState.value.pending.firstOrNull { it.uuid == uuid } ?: return
        selectedDate = task.nextRemindAt.toLocalDate()
        requestReschedule(task)
    }

    /** 请求改期候选:新请求取消旧请求,返回时校验仍是当前卡片。 */
    fun requestReschedule(task: TaskEntity) {
        rescheduleJob?.cancel()
        rescheduleLoadingUuid = task.uuid
        reschedule = null
        rescheduleError = null
        rescheduleJob = viewModelScope.launch {
            try {
                val candidates = DeepSeekClient.suggestReschedule(
                    app.settings.aiConfig(), task.title, task.remindAt,
                    task.durationMinutes, task.isRecurring,
                )
                if (rescheduleLoadingUuid == task.uuid) {
                    reschedule = task.uuid to candidates
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (rescheduleLoadingUuid == task.uuid) rescheduleError = e.message
            } finally {
                if (rescheduleLoadingUuid == task.uuid) rescheduleLoadingUuid = null
            }
        }
    }

    fun applyReschedule(uuid: String, at: LocalDateTime) {
        reschedule = null
        viewModelScope.launch { app.repository.reschedule(uuid, at) }
    }

    fun dismissReschedule() {
        reschedule = null
    }

    // ---- 已完成页:恢复 + 每周完成洞察 ----

    fun restore(uuid: String) = viewModelScope.launch { app.repository.restore(uuid) }

    /** 每周完成洞察文本(正向、低负担;ISO 周缓存)。 */
    var insight by mutableStateOf<String?>(null)
        private set

    /** 本地统计近 7 天完成情况,AI 只负责说成一句正向的话;失败静默不显示。 */
    fun loadInsight() = viewModelScope.launch {
        val settings = app.settings.snapshot()
        if (!settings.insightEnabled) {
            insight = null
            return@launch
        }
        val config = app.settings.aiConfig()
        if (config.apiKey.isNullOrBlank()) return@launch
        val prefs = app.getSharedPreferences("insight", 0)
        val weekFields = java.time.temporal.WeekFields.ISO
        val today = LocalDate.now()
        val stamp = "${today.get(weekFields.weekBasedYear())}-" +
            "${today.get(weekFields.weekOfWeekBasedYear())}"
        if (prefs.getString("week", null) == stamp) {
            insight = prefs.getString("text", null)
            return@launch
        }
        val done = uiState.value.done
        val now = LocalDateTime.now()
        val weekAgo = now.minusDays(7)
        val twoWeeksAgo = now.minusDays(14)
        val recent = done.filter { it.doneAt?.isAfter(weekAgo) == true }
        if (recent.isEmpty()) return@launch
        val previous = done.filter {
            val d = it.doneAt ?: return@filter false
            d.isAfter(twoWeeksAgo) && !d.isAfter(weekAgo)
        }
        var stats = "近 7 天完成 ${recent.size} 件(再往前 7 天完成 ${previous.size} 件)"
        recent.mapNotNull { it.doneAt?.hour }
            .groupingBy { it }.eachCount()
            .maxByOrNull { it.value }?.key
            ?.let { stats += ";最常完成时段:$it 点左右" }
        stats += ";最近完成:" + recent.take(5).joinToString("、") { it.title }
        runCatching { DeepSeekClient.weeklyInsight(config, stats) }.getOrNull()?.let { text ->
            prefs.edit().putString("week", stamp).putString("text", text).apply()
            insight = text
        }
    }

    /** 编辑弹层里的"AI 修改",由弹层自行管理忙碌/错误状态。 */
    suspend fun aiEdit(current: ParsedTask, instruction: String): ParsedTask =
        DeepSeekClient.edit(app.settings.aiConfig(), current, instruction)

    fun delete(uuid: String) = viewModelScope.launch { app.repository.delete(uuid) }
    fun snooze(uuid: String) = viewModelScope.launch { app.repository.snooze(uuid) }
    fun saveNew(parsed: ParsedTask) = viewModelScope.launch { app.repository.saveNew(parsed) }
    fun applyEdit(uuid: String, parsed: ParsedTask) =
        viewModelScope.launch { app.repository.applyEdit(uuid, parsed) }
}
