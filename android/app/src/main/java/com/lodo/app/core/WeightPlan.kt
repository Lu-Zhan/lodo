package com.lodo.app.core

import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.util.UUID
import kotlin.math.abs
import kotlin.math.round

data class WeightGoal(val heightCm: Double? = null, val targetWeightKg: Double? = null, val targetBodyFatPercent: Double? = null)
data class WeightEntry(val id: String, val date: LocalDateTime, val weightKg: Double?, val bodyFatPercent: Double?, val fromHealth: Boolean = false)
object WeightPlan {
    fun merge(records: List<WeightEntry>, health: List<HealthDailyPoint>): List<WeightEntry> {
        val recorded = records.filter { it.weightKg != null }.map { it.date.toLocalDate() }.toSet()
        return (records + health.filter { it.date !in recorded && it.value > 0 }.map {
            WeightEntry("health-${it.date}", it.date.atStartOfDay(), it.value, null, true)
        }).sortedBy { it.date }
    }
    fun latestWeight(entries: List<WeightEntry>) = entries.lastOrNull { it.weightKg != null }
    fun latestBodyFat(entries: List<WeightEntry>) = entries.lastOrNull { it.bodyFatPercent != null }
    fun remaining(current: Double?, target: Double?): Double? = if (current == null || target == null) null else current - target
    fun progress(start: Double?, current: Double?, target: Double?): Double? {
        if (start == null || current == null || target == null) return null
        return if (abs(target - start) <= 0.05) { if (abs(current - target) <= 0.05) 1.0 else 0.0 }
        else ((current - start) / (target - start)).coerceIn(0.0, 1.0)
    }
    fun bmi(weightKg: Double?, heightCm: Double?): Double? = if (weightKg == null || heightCm == null || heightCm <= 50) null else weightKg / (heightCm / 100).let { it * it }
    enum class BMIBand { UNDER, NORMAL, OVER, OBESE }
    fun band(bmi: Double) = when { bmi < 18.5 -> BMIBand.UNDER; bmi < 24 -> BMIBand.NORMAL; bmi < 28 -> BMIBand.OVER; else -> BMIBand.OBESE }
    fun change(entries: List<WeightEntry>, days: Int, now: LocalDateTime): Double? {
        val window = entries.filter { it.weightKg != null && it.date >= now.minusDays(days.toLong()) && it.date <= now }
        return if (window.size < 2) null else window.last().weightKg!! - window.first().weightKg!!
    }
    fun composition(weightKg: Double?, bodyFatPercent: Double?): Pair<Double, Double>? {
        if (weightKg == null || bodyFatPercent == null || bodyFatPercent <= 0 || bodyFatPercent >= 80) return null
        val fat = weightKg * bodyFatPercent / 100
        return fat to weightKg - fat
    }
    fun promptSummary(entries: List<WeightEntry>, goal: WeightGoal, now: LocalDateTime): String? {
        val lines = mutableListOf<String>()
        goal.heightCm?.let { lines += "身高 ${format(it)} 厘米" }
        latestWeight(entries)?.let { e -> e.weightKg?.let { w ->
            lines += "当前体重 ${format(w)} 公斤(${e.date.toLocalDate()})"
            bmi(w, goal.heightCm)?.let { lines += "BMI ${format(it)}" }
        } }
        goal.targetWeightKg?.let { lines += "目标体重 ${format(it)} 公斤" }
        latestBodyFat(entries)?.let { lines += "当前体脂率 ${format(it.bodyFatPercent!!)}%(${it.date.toLocalDate()})" }
        goal.targetBodyFatPercent?.let { lines += "目标体脂率 ${format(it)}%" }
        for (days in listOf(7, 30)) change(entries, days, now)?.let { lines += "最近 $days 天体重变化 ${signed(it)} 公斤" }
        return lines.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }
    fun format(value: Double): String { val rounded = round(value * 10) / 10; return if (rounded % 1 == 0.0) rounded.toLong().toString() else String.format(java.util.Locale.ROOT, "%.1f", rounded) }
    fun signed(value: Double) = if (format(abs(value)) == "0") "0" else (if (value > 0) "+" else "-") + format(abs(value))
}

data class Nutrition(val calories: Double = 0.0, val proteinG: Double = 0.0, val fatG: Double = 0.0, val carbsG: Double = 0.0) {
    operator fun plus(other: Nutrition) = Nutrition(calories + other.calories, proteinG + other.proteinG, fatG + other.fatG, carbsG + other.carbsG)
}
data class NutritionItem(val name: String, val amount: String, val nutrition: Nutrition)
data class NutritionEstimate(val items: List<NutritionItem>) {
    val total get() = items.fold(Nutrition()) { a, item -> a + item.nutrition }
    companion object {
        fun number(raw: Any?, upper: Double): Double {
            val value = when (raw) {
                is Number -> raw.toDouble()
                is String -> raw.takeWhile { it in '0'..'9' || it == '.' || it == ' ' }.trim().toDoubleOrNull()
                else -> null
            }
            return value?.takeIf { it.isFinite() && it > 0 && it <= upper } ?: 0.0
        }
        fun parse(payload: JSONObject): NutritionEstimate? {
            val array = payload.optJSONArray("items") ?: return null
            val items = (0 until array.length()).mapNotNull { i ->
                val item = array.optJSONObject(i) ?: return@mapNotNull null
                val name = item.optString("name").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                NutritionItem(name, item.optString("amount").trim(), Nutrition(number(item.opt("calories"), 5000.0),
                    number(item.opt("protein"), 1000.0), number(item.opt("fat"), 1000.0), number(item.opt("carbs"), 1000.0)))
            }.take(30)
            return items.takeIf { it.isNotEmpty() }?.let(::NutritionEstimate)
        }
    }
}
data class WeightDietMeal(val id: String = UUID.randomUUID().toString(), val meal: String, val time: String, val food: String,
                          val calories: Int? = null, val taskUuid: String? = null) {
    val taskTitle get() = if (meal.isBlank()) food else "$meal:$food"
}
data class WeightDietPlan(val advice: String, val meals: List<WeightDietMeal>, val day: LocalDate) {
    val totalCalories: Int? get() = meals.mapNotNull { it.calories }.takeIf { it.isNotEmpty() }?.sum()
    fun remindAt(meal: WeightDietMeal, now: LocalDateTime): LocalDateTime {
        val time = java.time.LocalTime.parse(meal.time)
        val base = day.atTime(time)
        if (base > now) return base
        val todayAt = now.toLocalDate().atTime(time)
        return if (todayAt > now) todayAt else todayAt.plusDays(1)
    }
    companion object {
        fun parse(payload: JSONObject, day: LocalDate): WeightDietPlan? {
            val advice = payload.optString("advice").trim()
            val array = payload.optJSONArray("meals")
            val meals = (0 until (array?.length() ?: 0)).mapNotNull { i ->
                val item = array?.optJSONObject(i) ?: return@mapNotNull null
                val food = item.optString("food").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val parts = item.optString("time").trim().split(":").mapNotNull { it.toIntOrNull() }
                val time = if (parts.size >= 2 && parts[0] in 0..23 && parts[1] in 0..59)
                    String.format(java.util.Locale.ROOT, "%02d:%02d", parts[0], parts[1]) else "12:00"
                val calories = NutritionEstimate.number(item.opt("calories"), 5000.0).takeIf { it > 0 }?.let { round(it).toInt() }
                WeightDietMeal(meal = item.optString("meal").trim(), time = time, food = food, calories = calories)
            }.sortedBy { it.time }.take(6)
            return if (advice.isEmpty() && meals.isEmpty()) null else WeightDietPlan(advice, meals, day)
        }
    }
}
