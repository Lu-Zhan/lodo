package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface TaskDao {
    @Query("SELECT * FROM tasks WHERE status = 'pending' ORDER BY nextRemindAtMillis")
    fun observePending(): Flow<List<TaskEntity>>

    @Query("SELECT * FROM tasks WHERE status = 'done' ORDER BY doneAtMillis DESC")
    fun observeDone(): Flow<List<TaskEntity>>

    @Query("SELECT * FROM tasks WHERE status = 'pending'")
    suspend fun pending(): List<TaskEntity>

    @Query("SELECT * FROM tasks WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): TaskEntity?

    @Upsert
    suspend fun upsert(task: TaskEntity)

    @Query("DELETE FROM tasks WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    /** 条件化原子更新:只在当前仍是 pending 时才写入,返回受影响行数(0/1)。
     * 用来防止并发场景下(通知按钮、界面按钮、闹钟自我延续三条路径可能同时
     * 触发同一个 uuid 的 complete/snooze/persistNotified)重复处理同一次状态变更——
     * "读当前状态是否 pending"与"写入"之间不再有可被并发操作插入的窗口。 */
    @Query(
        """
        UPDATE tasks SET
            title = :title, remindAtMillis = :remindAtMillis,
            durationMinutes = :durationMinutes, allDay = :allDay,
            repeatType = :repeatType, repeatDays = :repeatDays, repeatTimes = :repeatTimes,
            status = :status, phase = :phase, nextRemindAtMillis = :nextRemindAtMillis,
            doneAtMillis = :doneAtMillis
        WHERE uuid = :uuid AND status = 'pending'
        """
    )
    suspend fun updateIfPendingRaw(
        uuid: String,
        title: String,
        remindAtMillis: Long,
        durationMinutes: Int,
        allDay: Boolean,
        repeatType: String,
        repeatDays: String,
        repeatTimes: String,
        status: String,
        phase: String,
        nextRemindAtMillis: Long,
        doneAtMillis: Long?,
    ): Int
}

/** [TaskDao.updateIfPendingRaw] 的便捷入口,直接传整份实体(Room 的 @Query 不支持
 * POJO 字段展开绑定,这里手动拆字段转调用)。 */
suspend fun TaskDao.updateIfPending(e: TaskEntity): Int = updateIfPendingRaw(
    uuid = e.uuid,
    title = e.title,
    remindAtMillis = e.remindAtMillis,
    durationMinutes = e.durationMinutes,
    allDay = e.allDay,
    repeatType = e.repeatType,
    repeatDays = e.repeatDays,
    repeatTimes = e.repeatTimes,
    status = e.status,
    phase = e.phase,
    nextRemindAtMillis = e.nextRemindAtMillis,
    doneAtMillis = e.doneAtMillis,
)
