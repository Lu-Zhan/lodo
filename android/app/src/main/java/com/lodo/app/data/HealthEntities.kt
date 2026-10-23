package com.lodo.app.data

import androidx.room.Entity
import androidx.room.PrimaryKey
import com.lodo.app.core.*
import java.time.LocalDate
import java.util.UUID

@Entity(tableName = "weight_records")
data class WeightRecordEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val dateMillis: Long = System.currentTimeMillis(),
    val weightKg: Double? = null, val bodyFatPercent: Double? = null, val note: String = "",
    val muscleMassKg: Double? = null, val visceralFatLevel: Double? = null, val basalMetabolicKcal: Double? = null,
    val bodyWaterPercent: Double? = null, val boneMassKg: Double? = null, val reportUuid: String? = null,
    val createdAtMillis: Long = System.currentTimeMillis(),
) {
    fun entry() = WeightEntry(uuid, dateMillis.toLocalDateTime(), weightKg, bodyFatPercent)
}
@Entity(tableName = "food_records")
data class FoodRecordEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val dateMillis: Long = System.currentTimeMillis(), val text: String,
    val estimated: Boolean = false, val calories: Double = 0.0, val proteinG: Double = 0.0,
    val fatG: Double = 0.0, val carbsG: Double = 0.0, val itemsData: String = "",
    val createdAtMillis: Long = System.currentTimeMillis(),
) {
    val nutrition get() = if (estimated) Nutrition(calories, proteinG, fatG, carbsG) else Nutrition()
}
@Entity(tableName = "medications")
data class MedicationEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val name: String, val dosage: String = "", val note: String = "",
    val times: String = "", val days: String = "", val reminderEnabled: Boolean = false, val taskUuid: String? = null,
    val archived: Boolean = false, val createdAtMillis: Long = System.currentTimeMillis(),
) {
    fun entry() = MedicationPlan.Med(uuid, name, dosage, splitCsv(times), splitIntCsv(days), archived)
}
@Entity(tableName = "medication_doses")
data class MedicationDoseEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val medicationUuid: String?, val name: String, val dosage: String = "",
    val takenAtMillis: Long = System.currentTimeMillis(), val status: String = "taken", val source: String = "manual",
    val taskUuid: String? = null, val healthSampleId: String? = null, val note: String = "", val createdAtMillis: Long = System.currentTimeMillis(),
) {
    fun entry() = MedicationPlan.Dose(uuid, medicationUuid, takenAtMillis.toLocalDateTime(),
        if (status == "skipped") MedicationPlan.Status.SKIPPED else MedicationPlan.Status.TAKEN, healthSampleId)
}
@Entity(tableName = "period_records")
data class PeriodRecordEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val startDay: String, val endDay: String? = null,
    val note: String = "", val createdAtMillis: Long = System.currentTimeMillis(),
) {
    fun entry() = CyclePeriod(uuid, LocalDate.parse(startDay), endDay?.let(LocalDate::parse))
}
@Entity(tableName = "period_flow_records")
data class PeriodFlowEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val dayKey: String, val levelRaw: String,
    val updatedAtMillis: Long = System.currentTimeMillis(), val isDeleted: Boolean = false, val createdAtMillis: Long = System.currentTimeMillis(),
) {
    fun entry() = CycleFlow.ManualEntry(uuid, dayKey, levelRaw, updatedAtMillis, isDeleted)
}
@Entity(tableName = "health_profiles")
data class HealthProfileEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val name: String, val relation: String = "", val birthday: String? = null,
    val notes: String = "", val createdAtMillis: Long = System.currentTimeMillis(),
)
@Entity(tableName = "checkup_entries")
data class CheckupEntryEntity(
    @PrimaryKey val uuid: String = UUID.randomUUID().toString(), val reportUuid: String, val profileUuid: String? = null,
    val kind: String = "item", val category: String = "", val name: String = "", val value: String = "", val unit: String = "",
    val referenceRange: String = "", val flag: String = "", val conclusion: String = "", val advice: String = "",
    val dateDay: String, val sortIndex: Int = 0, val createdAtMillis: Long = System.currentTimeMillis(),
)
