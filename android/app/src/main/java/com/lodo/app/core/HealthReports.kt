package com.lodo.app.core

import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.util.UUID
import kotlin.math.round

/** 和 iOS WeightReport 相同:每项独立换算/丢弃,不把异常值裁成边界值。 */
data class WeightMeasurement(val id: String = UUID.randomUUID().toString(), val date: LocalDateTime? = null, val dateOnly: Boolean = false,
    val weightKg: Double? = null, val bodyFatPercent: Double? = null, val muscleMassKg: Double? = null,
    val visceralFatLevel: Double? = null, val basalMetabolicKcal: Double? = null, val bodyWaterPercent: Double? = null, val boneMassKg: Double? = null) {
    val hasValue get() = listOf(weightKg, bodyFatPercent, muscleMassKg, visceralFatLevel, basalMetabolicKcal, bodyWaterPercent, boneMassKg).any { it != null }
}
data class ParsedWeightReport(val title: String, val device: String, val measurements: List<WeightMeasurement>, val droppedValues: Int)
object WeightReport {
    fun number(raw: Any?): Double? = when (raw) {
        is Number -> raw.toDouble().takeIf { it.isFinite() }
        is String -> raw.trim().takeIf { it.matches(Regex("[0-9]*\\.?[0-9]+|[0-9]+\\.")) }?.toDoubleOrNull()?.takeIf { it.isFinite() }
        else -> null
    }
    fun massFactor(raw: Any?): Double? = when ((raw as? String).orEmpty().trim().lowercase()) {
        "", "kg", "公斤", "千克", "kilogram", "kilograms" -> 1.0
        "斤", "市斤", "jin" -> 0.5
        "lb", "lbs", "磅", "pound", "pounds" -> 0.45359237
        else -> null
    }
    fun parse(json: JSONObject, now: LocalDateTime = LocalDateTime.now()): ParsedWeightReport {
        val raw = json.optJSONArray("measurements") ?: error("无法解析:返回格式异常:缺少 measurements")
        var dropped = 0
        val result = (0 until raw.length()).mapNotNull { index ->
            val item = raw.optJSONObject(index) ?: return@mapNotNull null
            fun mass(key: String, range: ClosedFloatingPointRange<Double>): Double? {
                val value = number(item.opt(key)) ?: return null
                val factor = massFactor(if (item.has("${key}_unit")) item.opt("${key}_unit") else item.opt("mass_unit"))
                val kg = factor?.let { round(value * it * 100) / 100 }
                return kg?.takeIf { it in range } ?: run { dropped++; null }
            }
            fun plain(key: String, range: ClosedFloatingPointRange<Double>): Double? {
                val value = number(item.opt(key)) ?: return null
                return (round(value * 100) / 100).takeIf { it in range } ?: run { dropped++; null }
            }
            val weight = mass("weight", 1.0..500.0)
            var muscle = mass("muscle", 1.0..300.0)
            var bone = mass("bone", 0.1..20.0)
            if (weight != null && muscle != null && muscle >= weight) { muscle = null; dropped++ }
            if (weight != null && bone != null && bone >= weight) { bone = null; dropped++ }
            val bmr = number(item.opt("bmr"))?.let { value ->
                val kcal = when (item.optString("bmr_unit").trim().lowercase()) {
                    "", "kcal", "千卡", "大卡", "卡路里" -> value
                    "kj", "千焦" -> value / 4.184
                    else -> null
                }
                kcal?.let(::round)?.takeIf { it in 300.0..10000.0 } ?: run { dropped++; null }
            }
            val time = item.optString("time").trim().replace('T', ' ')
            val dateOnly = time.length == 10
            val parsed = runCatching {
                if (dateOnly) LocalDate.parse(time).atTime(12, 0) else LocalDateTime.parse(time.replace(' ', 'T'))
            }.getOrNull()
            val date = parsed?.takeIf { if (dateOnly) it.toLocalDate() <= now.toLocalDate() else it <= now.plusMinutes(5) }
                ?.let { if (dateOnly && it > now) now else it }
            WeightMeasurement(date = date, dateOnly = dateOnly && date != null, weightKg = weight, muscleMassKg = muscle, boneMassKg = bone,
                bodyFatPercent = plain("body_fat", 1.0..79.0), visceralFatLevel = plain("visceral_fat", 1.0..60.0),
                basalMetabolicKcal = bmr, bodyWaterPercent = plain("water", 1.0..99.0)).takeIf { it.hasValue }
        }.distinctBy { it.copy(id = "") }.sortedWith(compareBy(nullsLast()) { it.date })
        return ParsedWeightReport(json.optString("title").trim(), json.optString("device").trim(), result, dropped)
    }
}

data class ParsedCheckupItem(val category: String, val name: String, val value: String, val unit: String,
    val reference: String, val flag: String, val conclusion: String, val advice: String)
data class ParsedCheckupReport(val title: String, val date: LocalDate?, val institution: String, val items: List<ParsedCheckupItem>, val summaryAdvice: String)
object CheckupReport {
    fun parse(json: JSONObject): ParsedCheckupReport {
        val raw = json.optJSONArray("items") ?: error("无法解析:返回格式异常:缺少 items")
        fun text(o: JSONObject, key: String): String = when (val v = o.opt(key)) { is Number, is String -> v.toString().trim(); else -> "" }
        val items = (0 until raw.length()).mapNotNull { index ->
            val o = raw.optJSONObject(index) ?: return@mapNotNull null
            val name = text(o, "name").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            ParsedCheckupItem(text(o, "category"), name, text(o, "value"), text(o, "unit"), text(o, "reference"),
                text(o, "flag").lowercase().takeIf { it in setOf("high", "low", "abnormal", "normal") }.orEmpty(), text(o, "conclusion"), text(o, "advice"))
        }
        return ParsedCheckupReport(text(json, "title"), runCatching { LocalDate.parse(text(json, "date").take(10)) }.getOrNull(),
            text(json, "institution"), items, text(json, "summary_advice"))
    }
}
