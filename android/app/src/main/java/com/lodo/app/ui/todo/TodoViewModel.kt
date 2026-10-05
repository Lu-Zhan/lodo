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
import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Strings
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TaskStatus
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.localizedParsedTaskCaption
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
import java.util.Locale

/** 底部弹层模式,对应 iOS SheetMode。 */
sealed interface SheetMode {
    /** 快速添加页(AI 输入 + 手动表单)。 */
    data object Add : SheetMode
    data class Create(val parsed: ParsedTask?) : SheetMode
    data class Edit(val task: TaskEntity, val parsed: ParsedTask? = null) : SheetMode
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
    fun togglePin(uuid: String) = viewModelScope.launch { app.repository.togglePin(uuid) }
    fun snooze(uuid: String) = viewModelScope.launch { app.repository.snooze(uuid) }
    fun ignore(uuid: String) = viewModelScope.launch { app.repository.ignore(uuid) }
    fun saveNew(parsed: ParsedTask) = viewModelScope.launch { app.repository.saveNew(parsed) }
    fun applyEdit(uuid: String, parsed: ParsedTask) =
        viewModelScope.launch { app.repository.applyEdit(uuid, parsed) }
}
