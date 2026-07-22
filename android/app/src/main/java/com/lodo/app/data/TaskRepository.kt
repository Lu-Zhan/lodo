package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.DurationMemory
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.Scheduler
import com.lodo.app.core.TaskPhase
import com.lodo.app.core.TaskStatus
import com.lodo.app.notify.AlarmScheduler
import com.lodo.app.notify.Notifications
import java.time.LocalDateTime

/**
 * 事项业务层:界面按钮与通知按钮共用同一套完成/稍等逻辑
 * (对应 iOS NotificationManager 的 complete/snooze),保证两条路径行为一致。
 * 每个操作负责联动闹钟重排与通知清除。
 */
class TaskRepository(
    private val context: Context,
    private val dao: TaskDao,
    private val settings: SettingsRepository,
    private val alarms: AlarmScheduler,
) {
    /** 完成/开始了:advance;重复事项完成一次会记入历史并排下一次。
     * 返回插入的历史记录(仅重复事项完成一次时非 null)——agent 批量操作的
     * 撤销要记它的 uuid,一般调用方可以忽略返回值。 */
    suspend fun complete(uuid: String): TaskEntity? {
        val entity = dao.byUuid(uuid) ?: return null
        if (entity.statusEnum != TaskStatus.PENDING) return null
        val now = LocalDateTime.now()
        val (d, finished) = Scheduler.advance(entity.toData(), now)
        dao.upsert(entity.withData(d))
        var history: TaskEntity? = null
        if (finished && d.status == TaskStatus.PENDING) {
            // 重复事项完成一次:插入一条已完成历史
            history = TaskEntity.create(
                title = d.title, remindAt = now,
                status = TaskStatus.DONE, doneAt = now,
            )
            dao.upsert(history)
        }
        if (d.status == TaskStatus.DONE) {
            alarms.cancelReminder(uuid)
        } else {
            alarms.scheduleReminder(uuid, d.nextRemindAt)
        }
        Notifications.dismiss(context, uuid)
        if (finished) {
            // 完成一次(含重复事项)即作为时长记忆样本
            DurationMemory.learn(context, settings.aiConfig(), d.title, d.durationMinutes)
        }
        return history
    }

    /** 用户点"稍等"。 */
    suspend fun snooze(uuid: String) {
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.PENDING) return
        val d = Scheduler.snooze(entity.toData(), LocalDateTime.now(), settings.snapshot().snoozeMinutes)
        dao.upsert(entity.withData(d))
        alarms.scheduleReminder(uuid, d.nextRemindAt)
        Notifications.dismiss(context, uuid)
    }

    suspend fun delete(uuid: String) {
        alarms.cancelReminder(uuid)
        Notifications.dismiss(context, uuid)
        dao.delete(uuid)
    }

    /** 返回新建的实体——agent 批量操作的撤销要记它的 uuid。 */
    suspend fun saveNew(parsed: ParsedTask): TaskEntity {
        val entity = TaskEntity.create(
            title = parsed.title, remindAt = parsed.remindAt,
            durationMinutes = parsed.durationMinutes, allDay = parsed.allDay,
            repeatType = parsed.repeatType, repeatDays = parsed.repeatDays,
            repeatTimes = parsed.repeatTimes,
        )
        dao.upsert(entity)
        alarms.scheduleReminder(entity.uuid, entity.nextRemindAt)
        DurationMemory.learn(context, settings.aiConfig(), parsed.title, parsed.durationMinutes)
        return entity
    }

    /** 编辑保存:重置进行阶段,下次提醒回到新的提醒时间。仅对未完成事项生效。 */
    suspend fun applyEdit(uuid: String, parsed: ParsedTask) {
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.PENDING) return
        val updated = entity.copy(
            title = parsed.title,
            remindAtMillis = parsed.remindAt.toEpochMillis(),
            durationMinutes = parsed.durationMinutes,
            allDay = parsed.allDay,
            repeatType = parsed.repeatType.raw,
            repeatDays = joinIntCsv(parsed.repeatDays),
            repeatTimes = joinCsv(parsed.repeatTimes),
            phase = TaskPhase.START.raw,
            nextRemindAtMillis = parsed.remindAt.toEpochMillis(),
        )
        dao.upsert(updated)
        alarms.scheduleReminder(uuid, updated.nextRemindAt)
        Notifications.dismiss(context, uuid)
        DurationMemory.learn(context, settings.aiConfig(), parsed.title, parsed.durationMinutes)
    }

    /** 应用改期候选:非重复事项连 remindAt 一起改,重复事项只顺延本次。 */
    suspend fun reschedule(uuid: String, at: LocalDateTime) {
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.PENDING) return
        val updated = entity.copy(
            remindAtMillis = if (entity.isRecurring) entity.remindAtMillis else at.toEpochMillis(),
            nextRemindAtMillis = at.toEpochMillis(),
        )
        dao.upsert(updated)
        alarms.scheduleReminder(uuid, updated.nextRemindAt)
        Notifications.dismiss(context, uuid)
    }

    /** 恢复为待办:回到 start 阶段,提醒时间取原定时间(已过期会直接进到期卡)。 */
    suspend fun restore(uuid: String) {
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.DONE) return
        val updated = entity.copy(
            status = TaskStatus.PENDING.raw,
            phase = TaskPhase.START.raw,
            doneAtMillis = null,
            nextRemindAtMillis = entity.remindAtMillis,
        )
        dao.upsert(updated)
        alarms.scheduleReminder(uuid, updated.nextRemindAt)
    }

    /** 重排全部待办的闹钟和每日汇总(app 回到前台、开机、设置变更时调用)。 */
    suspend fun syncAlarms() {
        dao.pending().forEach { alarms.scheduleReminder(it.uuid, it.nextRemindAt) }
        val s = settings.snapshot()
        if (s.digestEnabled) alarms.scheduleDigest(s) else alarms.cancelDigest()
    }

    // ---- agent 批量操作撤销专用 ----

    /** 把一份之前的快照原样写回(uuid 不变),按快照里的状态重排/取消闹钟。
     * Update/Complete/Delete 的撤销都是"用之前的状态覆盖/重新插入回去"。 */
    suspend fun restoreSnapshot(entity: TaskEntity) {
        dao.upsert(entity)
        if (entity.statusEnum == TaskStatus.PENDING) {
            alarms.scheduleReminder(entity.uuid, entity.nextRemindAt)
        } else {
            alarms.cancelReminder(entity.uuid)
        }
        Notifications.dismiss(context, entity.uuid)
    }

    /** 撤销快照捕获专用:即时查一次当前状态,不能用调用方手头可能已经过时的
     * UI 快照(agent 批量确认执行期间,目标事项可能已被通知按钮/Siri 并发
     * 改动;用陈旧状态当"撤销回去的原样"会在撤销时把并发的改动覆盖掉)。 */
    suspend fun current(uuid: String): TaskEntity? = dao.byUuid(uuid)

    suspend fun exists(uuid: String): Boolean = dao.byUuid(uuid) != null

    /** 撤销"新建"专用:目标还存在才删,已经被用户手动删掉就不重复处理
     * (返回是否真的删了,调用方据此计入"因事项已不存在无法撤销")。 */
    suspend fun removeIfExists(uuid: String): Boolean {
        if (dao.byUuid(uuid) == null) return false
        delete(uuid)
        return true
    }
}
