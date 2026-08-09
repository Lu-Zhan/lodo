package com.lodo.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TaskData
import java.time.LocalDateTime
import java.util.UUID

/**
 * 用户自定义的 AI 例行任务(定时任务),对应 iOS AIRoutine 的核心字段——到点
 * 自动跑一句用户自己写的指令(如"总结今日待办""看天气给穿搭建议")。触发时间
 * 复用待办的重复时间点格式(repeatType/repeatDays/repeatTimes),与
 * Scheduler.nextOccurrence 完全一致(见 [toTaskData]/RoutineRepository)。
 * iOS 靠 BGAppRefreshTask + 预排通知兜底触发,Android 用 WorkManager 周期性
 * 检查(RoutineCheckWorker)达到等价效果——两端触发机制不同是平台差异,不是
 * 需要对齐的地方(CLAUDE.md 里"各端架构差异"的同一类情况)。
 */
@Entity(
    tableName = "routines",
    indices = [Index(value = ["enabled", "nextRunAtMillis"])],
)
data class RoutineEntity(
    @PrimaryKey val uuid: String,
    /** 用户自己写的指令原话,如"总结今日待办"。 */
    val prompt: String,
    val remindAtMillis: Long,
    val repeatType: String,
    val repeatDays: String,
    val repeatTimes: String,
    val enabled: Boolean,
    val nextRunAtMillis: Long,
    val lastRunAtMillis: Long?,
    val lastResultText: String?,
    val createdAtMillis: Long,
) {
    val repeatTypeEnum: RepeatType get() = RepeatType.from(repeatType)
    val repeatDaysList: List<Int> get() = splitIntCsv(repeatDays)
    val repeatTimesList: List<String> get() = splitCsv(repeatTimes)
    val isRecurring: Boolean get() = repeatTypeEnum != RepeatType.NONE
    val nextRunAt: LocalDateTime get() = nextRunAtMillis.toLocalDateTime()
    val lastRunAt: LocalDateTime? get() = lastRunAtMillis?.toLocalDateTime()

    /** 复用 Scheduler.nextOccurrence 计算下一次触发时间,不用另写一套时间推算
     * 逻辑——和 iOS RoutineSchedule 复用 Scheduler 语义是同一个思路。 */
    fun toTaskData() = TaskData(
        title = prompt, remindAt = remindAtMillis.toLocalDateTime(),
        repeatType = repeatTypeEnum, repeatDays = repeatDaysList, repeatTimes = repeatTimesList,
    )

    companion object {
        fun create(
            prompt: String, remindAt: LocalDateTime,
            repeatType: RepeatType = RepeatType.NONE,
            repeatDays: List<Int> = emptyList(), repeatTimes: List<String> = emptyList(),
        ) = RoutineEntity(
            uuid = UUID.randomUUID().toString(),
            prompt = prompt,
            remindAtMillis = remindAt.toEpochMillis(),
            repeatType = repeatType.raw,
            repeatDays = joinIntCsv(repeatDays),
            repeatTimes = joinCsv(repeatTimes),
            enabled = true,
            nextRunAtMillis = remindAt.toEpochMillis(),
            lastRunAtMillis = null,
            lastResultText = null,
            createdAtMillis = LocalDateTime.now().toEpochMillis(),
        )
    }
}

/** 一次执行记录,对应 iOS AIRoutineRun。 */
@Entity(tableName = "routine_runs")
data class RoutineRunEntity(
    @PrimaryKey val uuid: String,
    val routineUuid: String,
    val resultText: String,
    val ranAtMillis: Long,
) {
    companion object {
        fun create(routineUuid: String, resultText: String) = RoutineRunEntity(
            uuid = UUID.randomUUID().toString(),
            routineUuid = routineUuid,
            resultText = resultText,
            ranAtMillis = LocalDateTime.now().toEpochMillis(),
        )
    }
}
