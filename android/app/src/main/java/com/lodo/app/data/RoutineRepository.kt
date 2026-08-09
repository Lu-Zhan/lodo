package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Scheduler
import com.lodo.app.notify.Notifications
import kotlinx.coroutines.flow.Flow
import java.time.LocalDateTime

/**
 * 定时任务(AI 例行任务)业务层,对应 iOS RoutineRunner 的核心执行路径——
 * 触发机制不同(iOS 是 BGAppRefreshTask + 通知兜底,Android 是 WorkManager
 * 周期检查,见 RoutineCheckWorker),但"到点跑指令、记结果、推通知、算下一次"
 * 这条主逻辑一致。
 */
class RoutineRepository(
    private val context: Context,
    private val db: LodoDatabase,
    private val settings: SettingsRepository,
) {
    private val dao get() = db.routineDao()

    fun observeAll(): Flow<List<RoutineEntity>> = dao.observeAll()

    suspend fun save(
        prompt: String, remindAt: LocalDateTime,
        repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>,
    ): RoutineEntity {
        val entity = RoutineEntity.create(prompt, remindAt, repeatType, repeatDays, repeatTimes)
        dao.upsert(entity)
        return entity
    }

    suspend fun update(
        uuid: String, prompt: String, remindAt: LocalDateTime,
        repeatType: RepeatType, repeatDays: List<Int>, repeatTimes: List<String>,
    ) {
        val existing = dao.byUuid(uuid) ?: return
        dao.upsert(
            existing.copy(
                prompt = prompt, remindAtMillis = remindAt.toEpochMillis(),
                repeatType = repeatType.raw, repeatDays = joinIntCsv(repeatDays),
                repeatTimes = joinCsv(repeatTimes), nextRunAtMillis = remindAt.toEpochMillis(),
            )
        )
    }

    suspend fun setEnabled(uuid: String, enabled: Boolean) {
        val existing = dao.byUuid(uuid) ?: return
        // 重新启用时下一次触发从"现在"往后算,不是沿用禁用前可能早就过去的
        // nextRunAtMillis——不然重新打开开关会立刻触发一次意外执行。
        val nextRun = if (enabled) {
            Scheduler.nextOccurrence(existing.toTaskData(), LocalDateTime.now())
                ?: LocalDateTime.now()
        } else {
            existing.nextRunAt
        }
        dao.upsert(existing.copy(enabled = enabled, nextRunAtMillis = nextRun.toEpochMillis()))
    }

    suspend fun delete(uuid: String) = dao.delete(uuid)

    /** RoutineCheckWorker 每次唤醒调用:执行所有到点且启用的例行任务,记录
     * 结果,顺延下一次(非重复的执行一次后自动禁用,与待办 remindOnce 语义
     * 对称),并推一条通知——iOS 前台补跑不推通知、后台跑完才推,Android 没有
     * 前台/后台两条腿走路的机制,统一推通知(简单、稳妥,不算破坏对齐,是
     * 触发机制差异的自然结果)。 */
    suspend fun runDue() {
        val now = LocalDateTime.now()
        val due = dao.due(now.toEpochMillis())
        for (routine in due) {
            val result = try {
                DeepSeekClient.runRoutine(settings.aiConfig(), routine.prompt)
            } catch (e: Exception) {
                "执行失败:${e.message}"
            }
            dao.insertRun(RoutineRunEntity.create(routine.uuid, result))
            val next = Scheduler.nextOccurrence(routine.toTaskData(), now)
            dao.upsert(
                routine.copy(
                    lastRunAtMillis = now.toEpochMillis(),
                    lastResultText = result,
                    nextRunAtMillis = (next ?: now).toEpochMillis(),
                    // 非重复任务跑完一次就没有"下一次"了,自动禁用(避免
                    // nextRunAtMillis 停在过去、每次 worker 唤醒都被当成到期
                    // 重新执行)。
                    enabled = next != null,
                )
            )
            Notifications.showRoutineResult(context, routine.prompt, result)
        }
    }
}
