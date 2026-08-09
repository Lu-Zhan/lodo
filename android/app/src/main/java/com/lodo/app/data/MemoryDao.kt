package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface MemoryDao {
    @Query("SELECT * FROM memories ORDER BY createdAtMillis DESC")
    fun observeAll(): Flow<List<MemoryEntity>>

    @Query("SELECT * FROM memories ORDER BY createdAtMillis DESC")
    suspend fun all(): List<MemoryEntity>

    @Query("SELECT * FROM memories WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): MemoryEntity?

    @Upsert
    suspend fun upsert(item: MemoryEntity)

    @Query("DELETE FROM memories WHERE uuid = :uuid")
    suspend fun delete(uuid: String)
}
