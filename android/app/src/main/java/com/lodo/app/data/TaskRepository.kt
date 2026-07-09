package com.lodo.app.data

import android.content.Context
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
    /** 完成/开始了:advance;重复事项完成一次会记入历史并排下一次。 */
    suspend fun complete(uuid: String) {
        val entity = dao.byUuid(uuid) ?: return
        if (entity.statusEnum != TaskStatus.PENDING) return
        val now = LocalDateTime.now()
        val (d, finished) = Scheduler.advance(entity.toData(), now)
        dao.upsert(entity.withData(d))
        if (finished && d.status == TaskStatus.PENDING) {
            // 重复事项完成一次:插入一条已完成历史
            dao.upsert(
                TaskEntity.create(
                    title = d.title, remindAt = now,
                    status = TaskStatus.DONE, doneAt = now,
                )
            )
        }
        if (d.status == TaskStatus.DONE) {
            alarms.cancelReminder(uuid)
        } else {
            alarms.scheduleReminder(uuid, d.nextRemindAt)
        }
        Notifications.dismiss(context, uuid)
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

    suspend fun saveNew(parsed: ParsedTask) {
        val entity = TaskEntity.create(
            title = parsed.title, remindAt = parsed.remindAt,
            durationMinutes = parsed.durationMinutes, allDay = parsed.allDay,
            repeatType = parsed.repeatType, repeatDays = parsed.repeatDays,
            repeatTimes = parsed.repeatTimes,
        )
        dao.upsert(entity)
        alarms.scheduleReminder(entity.uuid, entity.nextRemindAt)
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
    }

    /** 重排全部待办的闹钟和每日汇总(app 回到前台、开机、设置变更时调用)。 */
    suspend fun syncAlarms() {
        dao.pending().forEach { alarms.scheduleReminder(it.uuid, it.nextRemindAt) }
        val s = settings.snapshot()
        if (s.digestEnabled) alarms.scheduleDigest(s.digestTime) else alarms.cancelDigest()
    }
}
