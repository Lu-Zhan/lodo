package com.lodo.app.core

import com.lodo.app.data.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

class HealthReportsTest {
    private val now = LocalDateTime.of(2026, 7, 8, 9, 0)
    private fun report(item: String) = WeightReport.parse(JSONObject("""{"measurements":[$item]}"""), now)
    @Test fun jinConverted() { assertEquals(60.0, report("""{"weight":120,"weight_unit":"斤"}""").measurements.single().weightKg!!, 0.001) }
    @Test fun poundsConverted() { assertEquals(45.36, report("""{"weight":100,"weight_unit":"lb"}""").measurements.single().weightKg!!, 0.001) }
    @Test fun unitsIndependent() {
        val m = report("""{"weight":120,"weight_unit":"斤","muscle":40,"muscle_unit":"kg"}""").measurements.single()
        assertEquals(60.0, m.weightKg!!, 0.001); assertEquals(40.0, m.muscleMassKg!!, 0.001)
    }
    @Test fun unspecifiedMassDefaultsToKg() { assertEquals(60.0, report("""{"weight":60}""").measurements.single().weightKg!!, 0.001) }
    @Test fun unknownUnitsDropped() { val r = report("""{"weight":60,"weight_unit":"oz","body_fat":20}"""); assertNull(r.measurements.single().weightKg); assertEquals(1, r.droppedValues) }
    @Test fun unreasonableValuesDroppedNotClamped() { val r = report("""{"weight":600,"body_fat":20}"""); assertNull(r.measurements.single().weightKg); assertEquals(1, r.droppedValues) }
    @Test fun booleansNotNumbers() { assertNull(WeightReport.number(true)); assertNull(WeightReport.number(false)) }
    @Test fun unitAndRangeStringsRejected() { assertNull(WeightReport.number("60kg")); assertNull(WeightReport.number("60-65")); assertNull(WeightReport.number("NaN")); assertNull(WeightReport.number(Double.POSITIVE_INFINITY)) }
    @Test fun numericStringsAllowed() { assertEquals(60.5, WeightReport.number(" 60.5 ")!!, 0.001) }
    @Test fun muscleCannotExceedWeight() { val r = report("""{"weight":60,"muscle":65}"""); assertNull(r.measurements.single().muscleMassKg); assertEquals(1, r.droppedValues) }
    @Test fun boneCannotEqualWeight() { assertNull(report("""{"weight":10,"bone":10}""").measurements.single().boneMassKg) }
    @Test fun bmrKilojoulesConverted() { assertEquals(1000.0, report("""{"bmr":4184,"bmr_unit":"kJ"}""").measurements.single().basalMetabolicKcal!!, 0.001) }
    @Test fun futureDateRequiresManualCorrection() { assertNull(report("""{"weight":60,"time":"2052-07-08"}""").measurements.single().date) }
    @Test fun todaysDateDoesNotCreateFutureNoonPoint() { assertEquals(now, report("""{"weight":60,"time":"2026-07-08"}""").measurements.single().date) }
    @Test fun futureClockSlackFiveMinutes() { assertNotNull(report("""{"weight":60,"time":"2026-07-08 09:05"}""").measurements.single().date); assertNull(report("""{"weight":60,"time":"2026-07-08 09:06"}""").measurements.single().date) }
    @Test fun invalidDayRequiresCorrection() { assertNull(report("""{"weight":60,"time":"2026-02-30"}""").measurements.single().date) }
    @Test fun allInvalidMeasurementOmitted() { assertTrue(report("""{"weight":600}""").measurements.isEmpty()) }
    @Test fun duplicateMeasurementsRemoved() { assertEquals(1, WeightReport.parse(JSONObject("""{"measurements":[{"weight":60,"time":"2026-07-07"},{"weight":60,"time":"2026-07-07"}]}"""), now).measurements.size) }
    @Test(expected = IllegalStateException::class) fun missingMeasurementsThrows() { WeightReport.parse(JSONObject("{}"), now) }
    @Test fun checkupSkipsNamelessItems() { assertEquals(1, CheckupReport.parse(JSONObject("""{"items":[{"value":5},{"name":"血糖","value":5.6}]}""")).items.size) }
    @Test fun checkupNumericValuePreserved() { assertEquals("5.6", CheckupReport.parse(JSONObject("""{"items":[{"name":"血糖","value":5.6}]}""")).items.single().value) }
    @Test fun checkupUnknownFlagNotInterpreted() { assertEquals("", CheckupReport.parse(JSONObject("""{"items":[{"name":"血糖","flag":"maybe"}]}""")).items.single().flag) }
    @Test fun checkupDoesNotInferAdvice() { assertEquals("", CheckupReport.parse(JSONObject("""{"items":[{"name":"血糖","value":"9","reference":"3.9-6.1"}]}""")).items.single().advice) }
    @Test(expected = IllegalStateException::class) fun missingCheckupItemsThrows() { CheckupReport.parse(JSONObject("{}")) }
    @Test fun weightBackupRoundTripAllMetrics() {
        val r = WeightRecordEntity(uuid = "w", weightKg = 60.0, bodyFatPercent = 20.0, note = "记录", muscleMassKg = 40.0, visceralFatLevel = 4.0, basalMetabolicKcal = 1500.0, bodyWaterPercent = 50.0, boneMassKg = 3.0, reportUuid = "report")
        assertEquals(r, weightFromJson(JSONObject(r.toJson().toString())))
    }
    @Test fun foodBackupRoundTrip() { val r = FoodRecordEntity(text = "面", estimated = true, calories = 500.0, proteinG = 10.0, itemsData = "[]"); assertEquals(r, foodFromJson(r.toJson())) }
    @Test fun medicationBackupRoundTrip() { val r = MedicationEntity(name = "药", times = "09:00,21:00", days = "0,2", reminderEnabled = true, taskUuid = "task"); assertEquals(r, medicationFromJson(r.toJson())) }
    @Test fun doseBackupRoundTrip() { val r = MedicationDoseEntity(medicationUuid = "med", name = "药", source = "task", taskUuid = "task"); assertEquals(r, doseFromJson(r.toJson())) }
    @Test fun periodBackupRoundTrip() { val r = PeriodRecordEntity(startDay = "2026-07-01", endDay = "2026-07-05"); assertEquals(r, periodFromJson(r.toJson())) }
    @Test fun flowTombstoneBackupRoundTrip() { val r = PeriodFlowEntity(dayKey = "2026-07-08", levelRaw = "none", isDeleted = true); assertEquals(r, flowFromJson(r.toJson())) }
    @Test fun familyProfileBackupRoundTrip() { val r = HealthProfileEntity(name = "家人", relation = "母亲", birthday = "1960-01-01"); assertEquals(r, profileFromJson(r.toJson())) }
    @Test fun reportMetadataBackupRoundTrip() {
        val r = MemoryEntity.create(MemoryKind.PDF, title = "体检报告").copy(checkupDateDay = "2026-07-08", checkupInstitution = "体检中心", checkupProfileUuid = "family", originalFileName = "报告.pdf", relativeFilePath = "Memory/report.pdf")
        assertEquals(r, memoryFromJson(r.toJson()))
    }
    @Test(expected = IllegalArgumentException::class) fun invalidReportDayRejected() {
        val r = MemoryEntity.create(MemoryKind.PDF).toJson().put("checkupDateDay", "2026-02-30")
        memoryFromJson(r)
    }
    @Test(expected = IllegalArgumentException::class) fun invalidPeriodDayRejectedBeforeImport() { validateHealthBackupRecord(PeriodRecordEntity(startDay = "2026-02-30")) }
    @Test(expected = IllegalArgumentException::class) fun reversedPeriodRejectedBeforeImport() { validateHealthBackupRecord(PeriodRecordEntity(startDay = "2026-07-08", endDay = "2026-07-01")) }
    @Test(expected = IllegalArgumentException::class) fun malformedMedicationTimeRejectedBeforeImport() { validateHealthBackupRecord(MedicationEntity(name = "药", times = "99:00")) }
    @Test fun familyCheckupBackupRoundTrip() { val r = CheckupEntryEntity(reportUuid = "report", profileUuid = "family", name = "血糖", value = "5.6", unit = "mmol/L", referenceRange = "3.9-6.1", flag = "normal", dateDay = "2026-07-08"); assertEquals(r, checkupFromJson(r.toJson())) }
}
