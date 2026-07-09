package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface TaskDao {
    @Query("SELECT * FROM tasks ORDER BY nextRemindAtMillis")
    fun observeAll(): Flow<List<TaskEntity>>

    @Query("SELECT * FROM tasks WHERE status = 'pending'")
    suspend fun pending(): List<TaskEntity>

    @Query("SELECT * FROM tasks WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): TaskEntity?

    @Upsert
    suspend fun upsert(task: TaskEntity)

    @Query("DELETE FROM tasks WHERE uuid = :uuid")
    suspend fun delete(uuid: String)
}
