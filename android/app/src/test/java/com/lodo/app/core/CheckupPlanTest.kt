package com.lodo.app.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class CheckupPlanTest {
    private val day = LocalDate.of(2026, 7, 8)
    private fun item(id: String = "a", name: String = "血糖", value: String = "5.6", report: String = "r", unit: String = "mmol/L", date: LocalDate = day, index: Int = 0) =
        CheckupEntryValue(id, report, name = name, value = value, unit = unit, date = date, sortIndex = index)
    @Test fun numericPrefixAndFlags() { assertEquals(5.6, CheckupPlan.numericValue("5.6↑")!!, 0.00001); assertEquals(10.0, CheckupPlan.numericValue("≥ 10")!!, 0.0) }
    @Test fun numericThousands() { assertEquals(1234.0, CheckupPlan.numericValue("1,234")!!, 0.0) }
    @Test fun plusAndRangeResultsNotNumeric() { listOf("阴性", "1+", "2-5/HP", "2~5", "5/HP").forEach { assertNull(it, CheckupPlan.numericValue(it)) } }
    @Test fun negativeNumberAllowed() { assertEquals(-1.5, CheckupPlan.numericValue("-1.5")!!, 0.0) }
    @Test fun malformedDecimalRejected() { assertNull(CheckupPlan.numericValue("1.2.3")) }
    @Test fun referenceRangeSeparators() { listOf("3.9-6.1", "3.9~6.1", "3.9～6.1", "3.9–6.1").forEach { assertEquals(CheckupPlan.Bounds(3.9, 6.1), CheckupPlan.referenceBounds(it)) } }
    @Test fun referenceUpperOnly() { assertEquals(CheckupPlan.Bounds(high = 5.2), CheckupPlan.referenceBounds("≤5.2")) }
    @Test fun referenceLowerOnly() { assertEquals(CheckupPlan.Bounds(low = 1.04), CheckupPlan.referenceBounds(">1.04")) }
    @Test fun negativeReferenceRange() { assertEquals(CheckupPlan.Bounds(-2.0, -1.0), CheckupPlan.referenceBounds("-2--1")) }
    @Test fun effectiveFlagUsesReportFlagFirst() { assertEquals("normal", item(value = "9").copy(reference = "3.9-6.1", flag = "normal").effectiveFlag) }
    @Test fun effectiveFlagDerivedWhenNotMarked() { assertEquals("high", item(value = "9").copy(reference = "3.9-6.1").effectiveFlag); assertEquals("low", item(value = "2").copy(reference = "3.9-6.1").effectiveFlag) }
    @Test fun noFlagForNonNumericOrNoReference() { assertNull(item(value = "阴性").effectiveFlag); assertNull(item().effectiveFlag) }
    @Test fun metricKeysNormalizeBracketsWhitespaceCase() { assertEquals(CheckupPlan.metricKey(" 总胆固醇（TC） "), CheckupPlan.metricKey("总胆固醇(tc)")) }
    @Test fun adviceNotMetric() { assertTrue(CheckupPlan.metrics(listOf(item().copy(kind = "advice"))).isEmpty()) }
    @Test fun sameDayDuplicateOnlyRemovedFromDisplay() { val records = listOf(item(), item("b")); assertEquals(1, CheckupPlan.metrics(records).single().records.size); assertEquals(2, records.size) }
    @Test fun sameDayDifferentResultsRemain() { assertEquals(2, CheckupPlan.metrics(listOf(item(), item("b", value = "6.0"))).single().records.size) }
    @Test fun historySortedAndLatestNameShown() {
        val metric = CheckupPlan.metrics(listOf(item("new", name = "TC", date = day), item("old", name = "tc", date = day.minusYears(1)))).single()
        assertEquals("TC", metric.name); assertEquals("old", metric.records.first().id)
    }
    @Test fun halfNumericIsNumeric() { assertTrue(CheckupPlan.metrics(listOf(item(), item("b", value = "未测", date = day.minusYears(1)))).single().isNumeric) }
    @Test fun knownNamesRecentOrderAndDedup() { assertEquals(listOf("TC"), CheckupPlan.knownNames(listOf(item("new", name = "TC"), item("old", name = "tc", date = day.minusYears(1))))) }
    @Test fun abbreviationRecognizesChineseAndPlain() { assertEquals("alt", CheckupNormalizer.abbreviation("谷丙转氨酶（ALT）")); assertEquals("alt", CheckupNormalizer.abbreviation("ALT")); assertNull(CheckupNormalizer.abbreviation("血糖")) }
    @Test fun localGroupsPreferChineseCanonical() {
        val catalog = CheckupNormalizer.catalog(listOf(item(name = "ALT"), item("b", name = "谷丙转氨酶(ALT)")))
        assertEquals("谷丙转氨酶(ALT)", CheckupNormalizer.localGroups(catalog).single().canonical)
    }
    @Test fun parseGroupsRejectsOutOfRangeAndReusedIds() {
        val catalog = CheckupNormalizer.catalog(listOf(item(name = "A"), item("b", name = "B"), item("c", name = "C")))
        val groups = CheckupNormalizer.parseGroups(JSONObject("""{"groups":[{"name":"AB","ids":[1,2,999]},{"name":"BC","ids":[2,3]}]}"""), catalog)
        assertEquals(1, groups.size); assertEquals("AB", groups.single().canonical)
    }
    @Test fun mergeGroupsTransitivelyWithAICanonicalFirst() {
        val merged = CheckupNormalizer.merge(listOf(CheckupNameGroup("AI名", listOf("A", "B"))), listOf(CheckupNameGroup("本地名", listOf("B", "C"))))
        assertEquals("AI名", merged.single().canonical); assertEquals(setOf("A", "B", "C"), merged.single().variants.toSet())
    }
    @Test fun normalizationRenamesWithoutMutatingInput() {
        val before = listOf(item(name = "A"))
        val plan = CheckupNormalizer.plan(before, listOf(CheckupNameGroup("B", listOf("A", "B"))))
        assertEquals("B", plan.updates["a"]!!.name); assertEquals("A", before.single().name)
    }
    @Test fun duplicatesOnlyWithinSameReport() {
        val plan = CheckupNormalizer.plan(listOf(item(), item("b", report = "r2")), emptyList())
        assertTrue(plan.removals.isEmpty())
    }
    @Test fun differentResultsNotDeleted() { assertTrue(CheckupNormalizer.plan(listOf(item(), item("b", value = "6.0")), emptyList()).removals.isEmpty()) }
    @Test fun equivalentNumbersCanBeDeduplicated() { assertEquals(1, CheckupNormalizer.plan(listOf(item(value = "5.60"), item("b", value = "5.6")), emptyList()).removals.size) }
    @Test fun differentUnitsWithDifferentRawResultsNotDeleted() { assertTrue(CheckupNormalizer.plan(listOf(item(value = "5.60", unit = "mg/dL"), item("b", value = "5.6")), emptyList()).removals.isEmpty()) }
    @Test fun duplicateFillsMissingFieldsInKeeper() {
        val a = item().copy(reference = "3.9-6.1", advice = "复查")
        val b = item("b").copy(conclusion = "原文结论")
        val plan = CheckupNormalizer.plan(listOf(a, b), emptyList())
        assertEquals(1, plan.removals.size); assertEquals("原文结论", plan.updates["a"]!!.conclusion)
    }
    @Test fun summaryIncludesAdviceAndChangesButBounded() {
        val summary = CheckupPlan.promptSummary(listOf(CheckupReportValue("r", "年度体检", day)), listOf(item(value = "9").copy(reference = "3.9-6.1"), item("advice").copy(kind = "advice", advice = "按报告复查")))!!
        assertTrue(summary.contains("异常项:")); assertTrue(summary.contains("报告综合建议:按报告复查"))
        assertTrue(CheckupPlan.promptSummary(listOf(CheckupReportValue("r", "年度体检", day)), listOf(item()), 10)!!.length <= 11)
    }
}
