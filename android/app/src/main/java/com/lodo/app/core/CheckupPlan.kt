package com.lodo.app.core

import java.time.LocalDate

/** 体检只做结果整理和参考范围比较,不生成诊断。纯快照不依赖 Room/Android。 */
data class CheckupEntryValue(val id: String, val reportId: String, val kind: String = "item", val category: String = "", val name: String = "",
    val value: String = "", val unit: String = "", val reference: String = "", val flag: String = "", val conclusion: String = "",
    val advice: String = "", val date: LocalDate, val sortIndex: Int = 0) {
    val numericValue get() = CheckupPlan.numericValue(value)
    val displayValue get() = if (value.trim().isEmpty()) conclusion else value.trim() + if (unit.isEmpty()) "" else " $unit"
    val effectiveFlag: String? get() {
        if (flag in setOf("high", "low", "abnormal", "normal")) return flag
        val number = numericValue ?: return null
        val bounds = CheckupPlan.referenceBounds(reference)
        return when {
            bounds.low != null && number < bounds.low -> "low"
            bounds.high != null && number > bounds.high -> "high"
            bounds.low == null && bounds.high == null -> null
            else -> "normal"
        }
    }
}
data class CheckupMetric(val key: String, val name: String, val category: String, val records: List<CheckupEntryValue>) {
    val latest get() = records.lastOrNull()
    val isNumeric get() = records.count { it.numericValue != null }.let { it > 0 && it * 2 >= records.size }
    val referenceBounds get() = CheckupPlan.referenceBounds(records.lastOrNull { it.reference.isNotEmpty() }?.reference.orEmpty())
}
data class CheckupReportValue(val id: String, val title: String, val date: LocalDate, val institution: String = "")
object CheckupPlan {
    fun promptSummary(reports: List<CheckupReportValue>, entries: List<CheckupEntryValue>, limit: Int = 1500): String? {
        val latest = reports.maxByOrNull { it.date } ?: return null
        val recent = entries.filter { it.reportId == latest.id }
        val lines = mutableListOf("最近一次体检:${latest.date}${latest.title.takeIf { it.isNotEmpty() }?.let { " $it" }.orEmpty()}")
        val abnormal = recent.filter { it.kind == "item" && it.effectiveFlag in setOf("high", "low", "abnormal") }
        if (abnormal.isEmpty()) lines += "异常项:无" else {
            lines += "异常项:"
            for (entry in abnormal) lines += "- ${entry.name} ${entry.displayValue}" + entry.reference.takeIf { it.isNotEmpty() }?.let { "(参考 $it)" }.orEmpty() + entry.advice.takeIf { it.isNotEmpty() }?.let { ";报告建议:$it" }.orEmpty()
        }
        recent.firstOrNull { it.kind in setOf("advice", "summary") && it.advice.isNotEmpty() }?.let { lines += "报告综合建议:${it.advice}" }
        val changes = metrics(entries).filter { it.isNumeric && it.records.count { r -> r.numericValue != null } >= 2 }
        if (changes.isNotEmpty()) {
            lines += "历次变化:"
            changes.forEach { metric -> lines += "- ${metric.name}:" + metric.records.filter { it.numericValue != null }.takeLast(4).joinToString(" → ") { "${it.date} ${java.math.BigDecimal.valueOf(it.numericValue!!).stripTrailingZeros().toPlainString()}" } }
        }
        val text = lines.joinToString("\n")
        return if (text.length > limit) text.take(limit) + "…" else text
    }
    data class Bounds(val low: Double? = null, val high: Double? = null)
    fun numericValue(text: String): Double? {
        var rest = text.trim()
        while (rest.firstOrNull()?.let { it in "<>≤≥＜＞=" } == true) rest = rest.drop(1).trimStart(' ')
        val match = Regex("^[+-]?[0-9.,]+").find(rest) ?: return null
        val digits = match.value.replace(",", "")
        if (!digits.any { it in '0'..'9' }) return null
        val number = digits.toDoubleOrNull()?.takeIf { it.isFinite() } ?: return null
        val tail = rest.drop(match.value.length).trim()
        if (tail.firstOrNull()?.let { it in "+-~/～–—" } == true) return null
        return number
    }
    fun referenceBounds(text: String): Bounds {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Bounds()
        if (trimmed.first() in "<≤＜") return Bounds(high = numericValue(trimmed.drop(1)))
        if (trimmed.first() in ">≥＞") return Bounds(low = numericValue(trimmed.drop(1)))
        for (separator in listOf('~', '～', '–', '—', '-')) {
            val index = trimmed.indexOf(separator, 1)
            if (index < 0) continue
            val bounds = Bounds(numericValue(trimmed.take(index)), numericValue(trimmed.drop(index + 1)))
            if (bounds.low != null || bounds.high != null) return bounds
        }
        return Bounds()
    }
    fun metricKey(name: String) = name.replace('（', '(').replace('）', ')').filterNot { it.isWhitespace() }.lowercase()
    private fun resultKey(entry: CheckupEntryValue) = entry.value.ifEmpty { entry.conclusion }.filterNot { it.isWhitespace() }.lowercase()
    fun metrics(entries: List<CheckupEntryValue>): List<CheckupMetric> {
        val ordered = entries.sortedWith(compareByDescending<CheckupEntryValue> { it.date }.thenBy { it.sortIndex })
        val categories = ordered.map { it.category }.distinct()
        return entries.filter { it.kind == "item" && metricKey(it.name).isNotEmpty() }.groupBy { metricKey(it.name) }.map { (key, values) ->
            val seen = mutableSetOf<String>()
            val records = values.sortedWith(compareBy<CheckupEntryValue> { it.date }.thenBy { it.sortIndex }).asReversed()
                .filter { seen.add("${it.date}|${resultKey(it)}") }.asReversed()
            val latest = records.last()
            CheckupMetric(key, latest.name, latest.category, records)
        }.sortedWith(compareBy<CheckupMetric> { categories.indexOf(it.category) }.thenBy { it.latest?.sortIndex ?: 0 })
    }
    fun knownNames(entries: List<CheckupEntryValue>, limit: Int = 200) = entries.filter { it.kind == "item" && it.name.isNotEmpty() }
        .sortedWith(compareByDescending<CheckupEntryValue> { it.date }.thenBy { it.sortIndex }).distinctBy { metricKey(it.name) }.take(limit).map { it.name }
    fun abnormalCount(entries: List<CheckupEntryValue>) = entries.count { it.kind == "item" && it.effectiveFlag in setOf("high", "low", "abnormal") }
}
