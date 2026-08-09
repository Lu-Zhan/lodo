package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface ContactRelationshipDao {
    @Query("SELECT * FROM contact_relationships")
    fun observeAll(): Flow<List<ContactRelationshipEntity>>

    @Query("SELECT * FROM contact_relationships WHERE fromUuid = :uuid OR toUuid = :uuid")
    suspend fun forContact(uuid: String): List<ContactRelationshipEntity>

    @Upsert
    suspend fun upsert(relationship: ContactRelationshipEntity)

    @Query("DELETE FROM contact_relationships WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    /** 记忆条目(人脉)被删除时联动清掉引用它的边——与 MemoryRepository.delete
     * 配合调用。 */
    @Query("DELETE FROM contact_relationships WHERE fromUuid = :uuid OR toUuid = :uuid")
    suspend fun deleteForContact(uuid: String)
}
