package com.lodo.app.ui.routine

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lodo.app.LodoApp
import com.lodo.app.core.RepeatType
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDateTime

class RoutineViewModel(application: Application) : AndroidViewModel(application) {
    private val app get() = getApplication<LodoApp>()

    val routines = app.routineRepository.observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun save(prompt: String, remindAt: LocalDateTime, repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>) =
        viewModelScope.launch { app.routineRepository.save(prompt, remindAt, repeatType, repeatDays, repeatTimes) }

    fun update(uuid: String, prompt: String, remindAt: LocalDateTime, repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>) =
        viewModelScope.launch { app.routineRepository.update(uuid, prompt, remindAt, repeatType, repeatDays, repeatTimes) }

    fun setEnabled(uuid: String, enabled: Boolean) = viewModelScope.launch {
        app.routineRepository.setEnabled(uuid, enabled)
    }

    fun delete(uuid: String) = viewModelScope.launch { app.routineRepository.delete(uuid) }
}
