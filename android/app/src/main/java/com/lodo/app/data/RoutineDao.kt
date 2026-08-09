package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface RoutineDao {
    @Query("SELECT * FROM routines ORDER BY nextRunAtMillis")
    fun observeAll(): Flow<List<RoutineEntity>>

    @Query("SELECT * FROM routines WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): RoutineEntity?

    /** RoutineCheckWorker 专用:到点且启用的例行任务。 */
    @Query("SELECT * FROM routines WHERE enabled = 1 AND nextRunAtMillis <= :nowMillis")
    suspend fun due(nowMillis: Long): List<RoutineEntity>

    @Upsert
    suspend fun upsert(routine: RoutineEntity)

    @Query("DELETE FROM routines WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    @Upsert
    suspend fun insertRun(run: RoutineRunEntity)
}
