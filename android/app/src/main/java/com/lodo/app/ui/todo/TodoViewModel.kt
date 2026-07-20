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
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.DurationMemory
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TaskStatus
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.TaskEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
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
        app.database.taskDao().observeAll(), ticker, app.settings.settings,
    ) { tasks, _, settings ->
        val now = LocalDateTime.now()
        // 计算下一次唤醒:最近一个未到期事项,否则 10 分钟兜底
        val nowMillis = System.currentTimeMillis()
        nextWakeDelayMillis = tasks
            .filter { it.statusEnum == TaskStatus.PENDING && it.nextRemindAtMillis > nowMillis }
            .minOfOrNull { it.nextRemindAtMillis - nowMillis + 1_000 }
            ?.coerceIn(1_000L, 600_000L) ?: 600_000L
        TodoUiState(
            due = tasks.filter { it.statusEnum == TaskStatus.PENDING && it.toData().isDue(now) },
            pending = tasks.filter { it.statusEnum == TaskStatus.PENDING },
            done = tasks.filter { it.statusEnum == TaskStatus.DONE }
                .sortedByDescending { it.doneAtMillis ?: 0L },
            snoozeMinutes = settings.snoozeMinutes,
            allDayTime = settings.allDayTime,
            hapticsEnabled = settings.hapticsEnabled,
            agentAutoRecordOnOpen = settings.agentAutoRecordOnOpen,
            agentSilenceTimeoutSeconds = settings.agentSilenceTimeoutSeconds,
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

    // ---- 全局 agent ----

    /**
     * agent 总入口:带上当前待办列表,把一句话解析成操作。
     * 单条新建/修改直达表单;批量或含完成/删除的进确认清单;信息缺失透传反问。
     */
    suspend fun agentRoute(text: String): AgentReply {
        val context = uiState.value.pending.map { it.uuid to it.toParsedTask() }
        return when (val result = DeepSeekClient.command(app.settings.aiConfig(), text,
            context.sortedBy { it.second.remindAt })) {
            is AICommandResult.Clarify -> AgentReply.Clarify(result.question, result.options)
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
                            ?: throw com.lodo.app.ai.DeepSeekException("无法解析:找不到要修改的事项")
                        sheet = SheetMode.Edit(entity, update.task)
                        return AgentReply.Routed
                    }
                }
                pendingActions = actions
                AgentReply.Confirm(actions.map(::describe))
            }
        }
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
    }

    private fun titleOf(uuid: String): String? =
        uiState.value.pending.firstOrNull { it.uuid == uuid }?.title

    /** 批量 agent 操作里有目标事项在确认期间被别处改动/删除时的提示。 */
    var actionsWarning by mutableStateOf<String?>(null)
        private set

    fun dismissActionsWarning() {
        actionsWarning = null
    }

    /** 执行确认后的批量操作,完毕关闭 agent。等待确认期间,目标事项可能已被
     * 通知按钮/Siri 改动或完成/删除;TaskRepository 对不存在的 uuid 是静默
     * no-op,这里先检查存在性、统计 missingCount,而不是让用户以为全部成功了。 */
    fun performPendingActions() = viewModelScope.launch {
        val pending = uiState.value.pending
        var missingCount = 0
        for (action in pendingActions) {
            when (action) {
                is AIAction.Create -> app.repository.saveNew(action.task)
                is AIAction.Update ->
                    if (pending.any { it.uuid == action.uuid }) {
                        app.repository.applyEdit(action.uuid, action.task)
                    } else {
                        missingCount++
                    }
                is AIAction.Complete ->
                    if (pending.any { it.uuid == action.uuid }) {
                        app.repository.complete(action.uuid)
                    } else {
                        missingCount++
                    }
                is AIAction.Delete ->
                    if (pending.any { it.uuid == action.uuid }) {
                        app.repository.delete(action.uuid)
                    } else {
                        missingCount++
                    }
            }
        }
        pendingActions = emptyList()
        sheet = null
        if (missingCount > 0) {
            actionsWarning = "有 $missingCount 项操作未执行:对应事项已不存在"
        }
    }

    /** agent 关闭时清掉未确认的操作,避免残留被后续误执行。 */
    fun clearPendingActions() {
        pendingActions = emptyList()
    }

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
