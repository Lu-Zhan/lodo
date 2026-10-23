package com.lodo.app.data

import org.json.JSONObject
import com.lodo.app.core.CycleFlow
import java.time.LocalTime

/** 导入在 Room 事务中验证,坏记录不能落库后把整个健康页的日期解析弄崩。 */
fun validateHealthBackupRecord(record: Any?) {
    fun day(value: String) { require(CycleFlow.date(value) != null) { "备份健康记录日期无效:$value" } }
    fun number(value: Double?) { require(value == null || value.isFinite() && value >= 0) { "备份健康读数无效" } }
    when (record) {
        is WeightRecordEntity -> {
            require(record.dateMillis.toLocalDateTime().year in 1..4000) { "备份测量日期无效" }
            listOf(record.weightKg, record.bodyFatPercent, record.muscleMassKg, record.visceralFatLevel, record.basalMetabolicKcal, record.bodyWaterPercent, record.boneMassKg).forEach(::number)
        }
        is FoodRecordEntity -> listOf(record.calories, record.proteinG, record.fatG, record.carbsG).forEach(::number)
        is MedicationEntity -> {
            require(record.name.isNotBlank()) { "备份药名为空" }
            splitCsv(record.times).forEach { require(it.matches(Regex("[0-9]{2}:[0-9]{2}")) && runCatching { LocalTime.parse(it) }.isSuccess) { "备份服药时间无效" } }
            if (record.days.isNotBlank()) record.days.split(',').forEach { require(it.trim().toIntOrNull() in 0..6) { "备份服药周几无效" } }
        }
        is MedicationDoseEntity -> require(record.status in setOf("taken", "skipped")) { "备份服药状态无效" }
        is PeriodRecordEntity -> { day(record.startDay); record.endDay?.let { day(it); require(it >= record.startDay) { "备份经期结束早于开始" } } }
        is PeriodFlowEntity -> day(record.dayKey)
        is HealthProfileEntity -> record.birthday?.let(::day)
        is CheckupEntryEntity -> day(record.dateDay)
    }
}

fun WeightRecordEntity.toJson() = JSONObject().put("uuid", uuid).put("dateMillis", dateMillis).put("weightKg", weightKg)
    .put("bodyFatPercent", bodyFatPercent).put("note", note).put("muscleMassKg", muscleMassKg).put("visceralFatLevel", visceralFatLevel)
    .put("basalMetabolicKcal", basalMetabolicKcal).put("bodyWaterPercent", bodyWaterPercent).put("boneMassKg", boneMassKg)
    .put("reportUuid", reportUuid).put("createdAtMillis", createdAtMillis)
fun weightFromJson(o: JSONObject) = WeightRecordEntity(uuid = o.getString("uuid"), dateMillis = o.getLong("dateMillis"),
    weightKg = o.dbl("weightKg"), bodyFatPercent = o.dbl("bodyFatPercent"), note = o.optString("note"),
    muscleMassKg = o.dbl("muscleMassKg"), visceralFatLevel = o.dbl("visceralFatLevel"), basalMetabolicKcal = o.dbl("basalMetabolicKcal"),
    bodyWaterPercent = o.dbl("bodyWaterPercent"), boneMassKg = o.dbl("boneMassKg"), reportUuid = o.str("reportUuid"),
    createdAtMillis = o.optLong("createdAtMillis", o.getLong("dateMillis")))
fun FoodRecordEntity.toJson() = JSONObject().put("uuid", uuid).put("dateMillis", dateMillis).put("text", text).put("estimated", estimated)
    .put("calories", calories).put("proteinG", proteinG).put("fatG", fatG).put("carbsG", carbsG).put("itemsData", itemsData).put("createdAtMillis", createdAtMillis)
fun foodFromJson(o: JSONObject) = FoodRecordEntity(uuid = o.getString("uuid"), dateMillis = o.getLong("dateMillis"), text = o.optString("text"),
    estimated = o.optBoolean("estimated"), calories = o.optDouble("calories", 0.0), proteinG = o.optDouble("proteinG", 0.0),
    fatG = o.optDouble("fatG", 0.0), carbsG = o.optDouble("carbsG", 0.0), itemsData = o.optString("itemsData"), createdAtMillis = o.optLong("createdAtMillis", o.getLong("dateMillis")))
fun MedicationEntity.toJson() = JSONObject().put("uuid", uuid).put("name", name).put("dosage", dosage).put("note", note).put("times", times)
    .put("days", days).put("reminderEnabled", reminderEnabled).put("taskUuid", taskUuid).put("archived", archived).put("createdAtMillis", createdAtMillis)
fun medicationFromJson(o: JSONObject) = MedicationEntity(uuid = o.getString("uuid"), name = o.getString("name"), dosage = o.optString("dosage"),
    note = o.optString("note"), times = o.optString("times"), days = o.optString("days"), reminderEnabled = o.optBoolean("reminderEnabled"),
    taskUuid = o.str("taskUuid"), archived = o.optBoolean("archived"), createdAtMillis = o.optLong("createdAtMillis"))
fun MedicationDoseEntity.toJson() = JSONObject().put("uuid", uuid).put("medicationUuid", medicationUuid).put("name", name).put("dosage", dosage)
    .put("takenAtMillis", takenAtMillis).put("status", status).put("source", source).put("taskUuid", taskUuid).put("healthSampleId", healthSampleId)
    .put("note", note).put("createdAtMillis", createdAtMillis)
fun doseFromJson(o: JSONObject) = MedicationDoseEntity(uuid = o.getString("uuid"), medicationUuid = o.str("medicationUuid"), name = o.optString("name"),
    dosage = o.optString("dosage"), takenAtMillis = o.getLong("takenAtMillis"), status = o.optString("status", "taken"), source = o.optString("source", "manual"),
    taskUuid = o.str("taskUuid"), healthSampleId = o.str("healthSampleId"), note = o.optString("note"), createdAtMillis = o.optLong("createdAtMillis", o.getLong("takenAtMillis")))
fun PeriodRecordEntity.toJson() = JSONObject().put("uuid", uuid).put("startDay", startDay).put("endDay", endDay).put("note", note).put("createdAtMillis", createdAtMillis)
fun periodFromJson(o: JSONObject) = PeriodRecordEntity(uuid = o.getString("uuid"), startDay = o.getString("startDay"), endDay = o.str("endDay"), note = o.optString("note"), createdAtMillis = o.optLong("createdAtMillis"))
fun PeriodFlowEntity.toJson() = JSONObject().put("uuid", uuid).put("dayKey", dayKey).put("levelRaw", levelRaw).put("updatedAtMillis", updatedAtMillis)
    .put("isDeleted", isDeleted).put("createdAtMillis", createdAtMillis)
fun flowFromJson(o: JSONObject) = PeriodFlowEntity(uuid = o.getString("uuid"), dayKey = o.getString("dayKey"), levelRaw = o.optString("levelRaw"),
    updatedAtMillis = o.getLong("updatedAtMillis"), isDeleted = o.optBoolean("isDeleted"), createdAtMillis = o.optLong("createdAtMillis", o.getLong("updatedAtMillis")))
fun HealthProfileEntity.toJson() = JSONObject().put("uuid", uuid).put("name", name).put("relation", relation).put("birthday", birthday).put("notes", notes).put("createdAtMillis", createdAtMillis)
fun profileFromJson(o: JSONObject) = HealthProfileEntity(uuid = o.getString("uuid"), name = o.getString("name"), relation = o.optString("relation"), birthday = o.str("birthday"), notes = o.optString("notes"), createdAtMillis = o.optLong("createdAtMillis"))
fun CheckupEntryEntity.toJson() = JSONObject().put("uuid", uuid).put("reportUuid", reportUuid).put("profileUuid", profileUuid).put("kind", kind)
    .put("category", category).put("name", name).put("value", value).put("unit", unit).put("referenceRange", referenceRange).put("flag", flag)
    .put("conclusion", conclusion).put("advice", advice).put("dateDay", dateDay).put("sortIndex", sortIndex).put("createdAtMillis", createdAtMillis)
fun checkupFromJson(o: JSONObject) = CheckupEntryEntity(uuid = o.getString("uuid"), reportUuid = o.getString("reportUuid"), profileUuid = o.str("profileUuid"),
    kind = o.optString("kind", "item"), category = o.optString("category"), name = o.optString("name"), value = o.optString("value"), unit = o.optString("unit"),
    referenceRange = o.optString("referenceRange"), flag = o.optString("flag"), conclusion = o.optString("conclusion"), advice = o.optString("advice"),
    dateDay = o.getString("dateDay"), sortIndex = o.optInt("sortIndex"), createdAtMillis = o.optLong("createdAtMillis"))
