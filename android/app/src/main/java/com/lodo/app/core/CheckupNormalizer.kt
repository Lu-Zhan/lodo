package com.lodo.app.core

import org.json.JSONObject

/** 和 iOS 相同的预览式归并:AI 只给编号组,改名和保守去重由本机决定。 */
data class CheckupNameGroup(val canonical: String, val variants: List<String>, val recordCount: Int = 0)
data class CheckupNormalizationPlan(val groups: List<CheckupNameGroup>, val updates: Map<String, CheckupEntryValue>, val removals: List<CheckupEntryValue>) {
    val isEmpty get() = updates.isEmpty() && removals.isEmpty()
}
object CheckupNormalizer {
    data class NameInfo(val name: String, val category: String, val unit: String, val sample: String, val count: Int)
    fun catalog(entries: List<CheckupEntryValue>, limit: Int = 300): List<NameInfo> = entries.filter { it.kind == "item" && CheckupPlan.metricKey(it.name).isNotEmpty() }
        .sortedWith(compareByDescending<CheckupEntryValue> { it.date }.thenBy { it.sortIndex }).groupBy { CheckupPlan.metricKey(it.name) }.values.take(limit).map { records ->
            val first = records.first()
            NameInfo(first.name, first.category, records.firstOrNull { it.unit.isNotEmpty() }?.unit.orEmpty(), first.displayValue, records.size)
        }
    fun promptLines(catalog: List<NameInfo>) = catalog.mapIndexed { i, info -> "${i + 1}|${info.name}|${info.category}|${info.unit}|${info.sample.replace('\n', ' ').take(30)}" }.joinToString("\n")
    fun parseGroups(json: JSONObject, catalog: List<NameInfo>): List<CheckupNameGroup> {
        val raw = json.optJSONArray("groups") ?: return emptyList()
        val used = mutableSetOf<Int>()
        return (0 until raw.length()).mapNotNull { i ->
            val group = raw.optJSONObject(i) ?: return@mapNotNull null
            val ids = group.optJSONArray("ids") ?: return@mapNotNull null
            val members = (0 until ids.length()).mapNotNull { n -> when (val v = ids.opt(n)) {
                is Number -> v.toDouble().takeIf { it.isFinite() && it in 1.0..catalog.size.toDouble() }?.toInt()
                is String -> v.trim().toIntOrNull()
                else -> null
            } }.filter { it in 1..catalog.size && it !in used }.distinct()
            if (members.size < 2) return@mapNotNull null
            used.addAll(members)
            val names = members.map { catalog[it - 1].name }
            CheckupNameGroup(group.optString("name").trim().ifEmpty { names.first() }, names)
        }
    }
    fun abbreviation(name: String): String? {
        val normalized = name.replace('（', '(').replace('）', ')')
        val open = normalized.lastIndexOf('('); val close = normalized.lastIndexOf(')')
        val candidate = (if (open >= 0 && close > open) normalized.substring(open + 1, close) else normalized).filterNot { it.isWhitespace() }
        return candidate.takeIf { it.length in 2..10 && it.all { c -> c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '-' } && it.any { c -> c in 'a'..'z' || c in 'A'..'Z' } }?.lowercase()
    }
    fun localGroups(catalog: List<NameInfo>): List<CheckupNameGroup> = catalog.mapNotNull { info -> abbreviation(info.name)?.let { it to info } }.groupBy({ it.first }, { it.second }).values
        .filter { it.size >= 2 }.map { members ->
            val canonical = members.maxWith(compareBy<NameInfo> { if (it.name.any { c -> c in '\u4e00'..'\u9fff' }) 1 else 0 }.thenBy { it.count }.thenBy { it.name.length }).name
            CheckupNameGroup(canonical, members.map { it.name })
        }
    fun merge(ai: List<CheckupNameGroup>, local: List<CheckupNameGroup>): List<CheckupNameGroup> {
        val result = mutableListOf<CheckupNameGroup>()
        for (group in ai + local) {
            val keys = group.variants.map(CheckupPlan::metricKey).toSet()
            val hits = result.indices.filter { index -> result[index].variants.any { CheckupPlan.metricKey(it) in keys } }
            val canonical = hits.firstOrNull()?.let { result[it].canonical } ?: group.canonical
            val names = (hits.flatMap { result[it].variants } + group.variants).distinctBy(CheckupPlan::metricKey)
            hits.asReversed().forEach(result::removeAt)
            result.add(hits.firstOrNull() ?: result.size, CheckupNameGroup(canonical, names))
        }
        return result
    }
    private fun score(e: CheckupEntryValue) = listOf(e.value, e.unit, e.reference, e.conclusion, e.advice).count { it.trim().isNotEmpty() } + if (e.flag.isEmpty()) 0 else 1
    private fun sameResult(a: CheckupEntryValue, b: CheckupEntryValue): Boolean {
        fun key(e: CheckupEntryValue) = e.value.ifEmpty { e.conclusion }.filterNot { it.isWhitespace() }.lowercase()
        val left = key(a); val right = key(b)
        if (left.isEmpty() || right.isEmpty() || left == right) return true
        return a.numericValue != null && a.numericValue == b.numericValue && (a.unit.isEmpty() || b.unit.isEmpty() || a.unit.lowercase() == b.unit.lowercase())
    }
    private fun fill(a: CheckupEntryValue, b: CheckupEntryValue) = a.copy(value = a.value.ifEmpty { b.value }, unit = a.unit.ifEmpty { b.unit }, reference = a.reference.ifEmpty { b.reference },
        conclusion = a.conclusion.ifEmpty { b.conclusion }, advice = a.advice.ifEmpty { b.advice }, category = a.category.ifEmpty { b.category }, flag = a.flag.ifEmpty { b.flag })
    fun plan(entries: List<CheckupEntryValue>, groups: List<CheckupNameGroup>): CheckupNormalizationPlan {
        val names = mutableMapOf<String, String>()
        groups.forEach { g -> (g.variants + g.canonical).forEach { names[CheckupPlan.metricKey(it)] = g.canonical } }
        val working = entries.associate { e -> e.id to if (e.kind == "item") e.copy(name = names[CheckupPlan.metricKey(e.name)] ?: e.name) else e }.toMutableMap()
        val removals = mutableListOf<CheckupEntryValue>()
        working.values.filter { it.kind == "item" && CheckupPlan.metricKey(it.name).isNotEmpty() }.groupBy { "${it.reportId}|${CheckupPlan.metricKey(it.name)}" }.toSortedMap().values.forEach { records ->
            var pool = records.sortedWith(compareByDescending<CheckupEntryValue>(::score).thenBy { it.sortIndex }.thenBy { it.id })
            while (pool.isNotEmpty()) {
                var keeper = pool.first()
                val rest = mutableListOf<CheckupEntryValue>()
                for (other in pool.drop(1)) if (sameResult(keeper, other)) {
                    keeper = fill(keeper, other); removals += entries.first { it.id == other.id }
                } else rest += other
                working[keeper.id] = keeper; pool = rest
            }
        }
        val removed = removals.map { it.id }.toSet()
        val updates = working.filter { (id, value) -> id !in removed && value != entries.first { it.id == id } }
        val shown = groups.mapNotNull { group ->
            val keys = group.variants.map(CheckupPlan::metricKey).toSet()
            if (entries.none { it.kind == "item" && CheckupPlan.metricKey(it.name) in keys && it.name != group.canonical }) null
            else group.copy(variants = group.variants.filter { it != group.canonical && entries.any { e -> e.kind == "item" && e.name == it } }.distinct(),
                recordCount = entries.count { it.kind == "item" && (CheckupPlan.metricKey(it.name) in keys || CheckupPlan.metricKey(it.name) == CheckupPlan.metricKey(group.canonical)) })
        }
        return CheckupNormalizationPlan(shown, updates, removals.sortedWith(compareBy<CheckupEntryValue> { it.date }.thenBy { it.sortIndex }))
    }
}
