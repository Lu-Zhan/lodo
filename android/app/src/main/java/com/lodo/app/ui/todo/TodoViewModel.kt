package com.lodo.app.ui.todo

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.TaskStatus
import com.lodo.app.data.TaskEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDateTime

/** 底部弹层模式:新建(可带 AI 解析结果预填)或编辑现有事项。 */
sealed interface SheetMode {
    data class Create(val parsed: ParsedTask?) : SheetMode
    data class Edit(val task: TaskEntity) : SheetMode
}

data class TodoUiState(
    val due: List<TaskEntity> = emptyList(),
    val pending: List<TaskEntity> = emptyList(),
    val done: List<TaskEntity> = emptyList(),
    val snoozeMinutes: Int = 15,
    val allDayTime: String = "09:00",
)

class TodoViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp

    /** 10 秒心跳,让"到期提醒"分组不依赖数据库变更也能及时出现。 */
    private val ticker = flow {
        while (true) {
            emit(Unit)
            delay(10_000)
        }
    }

    val uiState = combine(
        app.database.taskDao().observeAll(), ticker, app.settings.settings,
    ) { tasks, _, settings ->
        val now = LocalDateTime.now()
        TodoUiState(
            due = tasks.filter { it.statusEnum == TaskStatus.PENDING && it.toData().isDue(now) },
            pending = tasks.filter { it.statusEnum == TaskStatus.PENDING },
            done = tasks.filter { it.statusEnum == TaskStatus.DONE }
                .sortedByDescending { it.doneAtMillis ?: 0L },
            snoozeMinutes = settings.snoozeMinutes,
            allDayTime = settings.allDayTime,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), TodoUiState())

    var sheet by mutableStateOf<SheetMode?>(null)
    var nlText by mutableStateOf("")
    var aiBusy by mutableStateOf(false)
        private set
    var aiError by mutableStateOf<String?>(null)
        private set

    /** 自然语言 → AI 解析 → 打开预填好的新建弹层供确认。 */
    fun parseNL() {
        val text = nlText.trim()
        if (text.isEmpty() || aiBusy) return
        viewModelScope.launch {
            aiBusy = true
            aiError = null
            try {
                val parsed = DeepSeekClient.parse(app.settings.apiKey(), text)
                nlText = ""
                sheet = SheetMode.Create(parsed)
            } catch (e: Exception) {
                aiError = e.message
            } finally {
                aiBusy = false
            }
        }
    }

    /** 编辑弹层里的"AI 修改",由弹层自行管理忙碌/错误状态。 */
    suspend fun aiEdit(current: ParsedTask, instruction: String): ParsedTask =
        DeepSeekClient.edit(app.settings.apiKey(), current, instruction)

    fun complete(uuid: String) = viewModelScope.launch { app.repository.complete(uuid) }
    fun snooze(uuid: String) = viewModelScope.launch { app.repository.snooze(uuid) }
    fun delete(uuid: String) = viewModelScope.launch { app.repository.delete(uuid) }
    fun saveNew(parsed: ParsedTask) = viewModelScope.launch { app.repository.saveNew(parsed) }
    fun applyEdit(uuid: String, parsed: ParsedTask) =
        viewModelScope.launch { app.repository.applyEdit(uuid, parsed) }
}
