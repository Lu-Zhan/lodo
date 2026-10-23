package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface HealthDao {
    @Query("SELECT * FROM weight_records ORDER BY dateMillis") fun observeWeights(): Flow<List<WeightRecordEntity>>
    @Query("SELECT * FROM weight_records ORDER BY dateMillis") suspend fun weights(): List<WeightRecordEntity>
    @Upsert suspend fun saveWeight(record: WeightRecordEntity)
    @Query("DELETE FROM weight_records WHERE uuid = :id") suspend fun deleteWeight(id: String)
    @Query("SELECT * FROM food_records ORDER BY dateMillis DESC") fun observeFoods(): Flow<List<FoodRecordEntity>>
    @Query("SELECT * FROM food_records ORDER BY dateMillis DESC") suspend fun foods(): List<FoodRecordEntity>
    @Query("SELECT * FROM food_records WHERE uuid = :id") suspend fun food(id: String): FoodRecordEntity?
    @Upsert suspend fun saveFood(record: FoodRecordEntity)
    @Query("DELETE FROM food_records WHERE uuid = :id") suspend fun deleteFood(id: String)
    @Query("SELECT * FROM medications ORDER BY createdAtMillis") fun observeMedications(): Flow<List<MedicationEntity>>
    @Query("SELECT * FROM medications ORDER BY createdAtMillis") suspend fun medications(): List<MedicationEntity>
    @Query("SELECT * FROM medications WHERE uuid = :id") suspend fun medication(id: String): MedicationEntity?
    @Upsert suspend fun saveMedication(record: MedicationEntity)
    @Query("DELETE FROM medications WHERE uuid = :id") suspend fun deleteMedication(id: String)
    @Query("SELECT * FROM medication_doses ORDER BY takenAtMillis DESC") fun observeDoses(): Flow<List<MedicationDoseEntity>>
    @Query("SELECT * FROM medication_doses ORDER BY takenAtMillis DESC") suspend fun doses(): List<MedicationDoseEntity>
    @Upsert suspend fun saveDose(record: MedicationDoseEntity)
    @Query("DELETE FROM medication_doses WHERE uuid = :id") suspend fun deleteDose(id: String)
    @Query("DELETE FROM medication_doses WHERE taskUuid = :taskId AND createdAtMillis >= :since") suspend fun removeTaskDoses(taskId: String, since: Long)
    @Query("SELECT * FROM period_records ORDER BY startDay") fun observePeriods(): Flow<List<PeriodRecordEntity>>
    @Query("SELECT * FROM period_records ORDER BY startDay") suspend fun periods(): List<PeriodRecordEntity>
    @Upsert suspend fun savePeriod(record: PeriodRecordEntity)
    @Query("DELETE FROM period_records WHERE uuid = :id") suspend fun deletePeriod(id: String)
    @Query("SELECT * FROM period_flow_records ORDER BY dayKey") fun observeFlows(): Flow<List<PeriodFlowEntity>>
    @Query("SELECT * FROM period_flow_records ORDER BY dayKey") suspend fun flows(): List<PeriodFlowEntity>
    @Upsert suspend fun saveFlow(record: PeriodFlowEntity)
    @Query("SELECT * FROM health_profiles ORDER BY createdAtMillis") fun observeProfiles(): Flow<List<HealthProfileEntity>>
    @Query("SELECT * FROM health_profiles ORDER BY createdAtMillis") suspend fun profiles(): List<HealthProfileEntity>
    @Upsert suspend fun saveProfile(record: HealthProfileEntity)
    @Query("DELETE FROM health_profiles WHERE uuid = :id") suspend fun deleteProfile(id: String)
    @Query("SELECT * FROM checkup_entries ORDER BY dateDay DESC, sortIndex") fun observeCheckups(): Flow<List<CheckupEntryEntity>>
    @Query("SELECT * FROM checkup_entries ORDER BY dateDay DESC, sortIndex") suspend fun checkups(): List<CheckupEntryEntity>
    @Upsert suspend fun saveCheckup(record: CheckupEntryEntity)
    @Query("DELETE FROM checkup_entries WHERE uuid = :id") suspend fun deleteCheckup(id: String)
    @Query("DELETE FROM checkup_entries WHERE reportUuid = :id") suspend fun deleteReportEntries(id: String)
}
