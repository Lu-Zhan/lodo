package com.lodo.app.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.temporal.ChronoUnit

/** 收入/支出/信用卡的类型与周期,存储字符串与 iOS FinanceKind/FinanceCadence 一致。 */
enum class FinanceKind(val raw: String) {
    INCOME("income"), EXPENSE("expense"), CREDIT_CARD("creditCard");

    companion object {
        fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: INCOME
    }
}

enum class FinanceCadence(val raw: String, val monthlyFactor: Double?) {
    MONTHLY("monthly", 1.0), QUARTERLY("quarterly", 1.0 / 3), YEARLY("yearly", 1.0 / 12), IRREGULAR("irregular", null);

    companion object {
        fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: MONTHLY
    }
}

data class FinanceSnapshot(
    val id: String,
    val kind: FinanceKind,
    val title: String,
    val amount: Double? = null,
    val currency: String = "CNY",
    val cadence: FinanceCadence = FinanceCadence.MONTHLY,
    val dayOfMonth: Int? = null,
    val statementDay: Int? = null,
    val institution: String = "",
    val endDate: LocalDateTime? = null,
)

/** 资产/收支的纯计算,与 iOS FinancePlan 同义。换不出汇率的币种不参与求和、原样报回。 */
object FinancePlan {
    const val STALE_MONTHS = 3

    data class MonthlyTotal(
        val income: Double = 0.0,
        val expense: Double = 0.0,
        val missingCurrencies: List<String> = emptyList(),
        val irregularCount: Int = 0,
    ) {
        val net get() = income - expense
    }

    fun monthlyTotal(
        entries: List<FinanceSnapshot>, currency: String, now: LocalDateTime,
        convert: (Double, String, String) -> Double?,
    ): MonthlyTotal {
        var income = 0.0
        var expense = 0.0
        var irregular = 0
        val missing = sortedSetOf<String>()
        for (e in entries) {
            if (e.kind == FinanceKind.CREDIT_CARD) continue
            val amount = e.amount ?: continue
            if (e.kind == FinanceKind.EXPENSE && e.endDate != null && e.endDate.isBefore(now)) continue
            val factor = e.cadence.monthlyFactor
            if (factor == null) {
                irregular++
                continue
            }
            val converted = if (e.currency == currency) amount else convert(amount, e.currency, currency)
            if (converted == null) {
                missing += e.currency
                continue
            }
            if (e.kind == FinanceKind.INCOME) income += converted * factor else expense += converted * factor
        }
        return MonthlyTotal(income, expense, missing.toList(), irregular)
    }

    /** 下一个"每月 day 号"(含今天);31 号在小月落月末。 */
    fun nextDate(day: Int, onOrAfter: LocalDate): LocalDate {
        for (offset in 0..2) {
            val month = onOrAfter.plusMonths(offset.toLong()).withDayOfMonth(1)
            val date = month.withDayOfMonth(day.coerceIn(1, month.lengthOfMonth()))
            if (!date.isBefore(onOrAfter)) return date
        }
        return onOrAfter
    }

    fun nextDueDate(card: FinanceSnapshot, now: LocalDateTime): LocalDate? {
        if (card.kind != FinanceKind.CREDIT_CARD) return null
        return card.dayOfMonth?.let { nextDate(it, now.toLocalDate()) }
    }

    fun nextStatementDate(card: FinanceSnapshot, now: LocalDateTime): LocalDate? {
        if (card.kind != FinanceKind.CREDIT_CARD) return null
        return card.statementDay?.let { nextDate(it, now.toLocalDate()) }
    }

    data class CardReminder(val cardId: String, val dueDate: LocalDate, val remindAt: LocalDateTime, val cycle: String)

    /** 还款日前一天的全天提醒时刻;已经过了就取 now,同 iOS。 */
    fun reminder(card: FinanceSnapshot, allDayTime: String, now: LocalDateTime): CardReminder? {
        val due = nextDueDate(card, now) ?: return null
        val at = due.minusDays(1).atTime(CountdownPlan.parseTime(allDayTime))
        return CardReminder(card.id, due, if (at.isBefore(now)) now else at, due.toString())
    }

    fun monthsSince(date: LocalDateTime, now: LocalDateTime): Int =
        maxOf(0, ChronoUnit.MONTHS.between(date, now).toInt())

    data class NetWorth(
        val assets: Double = 0.0, val liabilities: Double = 0.0,
        val missingCurrencies: List<String> = emptyList(), val unvaluedCount: Int = 0,
    ) {
        val net get() = assets - liabilities
    }

    data class AssetAmount(val value: Double?, val liability: Double?, val currency: String)

    fun netWorth(items: List<AssetAmount>, currency: String, convert: (Double, String, String) -> Double?): NetWorth {
        var assets = 0.0
        var liabilities = 0.0
        var unvalued = 0
        val missing = sortedSetOf<String>()
        fun conv(amount: Double, from: String): Double? {
            if (from == currency) return amount
            return convert(amount, from, currency).also { if (it == null) missing += from }
        }
        for (i in items) {
            if (i.value != null) assets += conv(i.value, i.currency) ?: 0.0
            else if (i.liability == null) unvalued++
            if (i.liability != null) liabilities += conv(i.liability, i.currency) ?: 0.0
        }
        return NetWorth(assets, liabilities, missing.toList(), unvalued)
    }
}

/** 资产分类:预设就是持久化的中文标签本身,别改(同 iOS AssetCategory)。 */
object AssetCategory {
    val presets = listOf("房产", "车辆", "存款", "投资", "保险", "其他")

    fun category(tags: List<String>, reserved: Set<String>): String = tags.firstOrNull { it !in reserved } ?: "其他"

    fun orderedGroups(categories: List<String>): List<String> {
        val custom = categories.filter { it !in presets }.distinct()
        val used = categories.toSet()
        return presets.dropLast(1).filter { it in used } + custom + (if ("其他" in used) listOf("其他") else emptyList())
    }
}
