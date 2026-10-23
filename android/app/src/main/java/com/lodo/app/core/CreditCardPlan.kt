package com.lodo.app.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.YearMonth

/** 持久化字符串与 iOS 一致。 */
enum class CardReminderKind(val raw: String) { STATEMENT("statement"), REPAYMENT("repayment"), ANNUAL_FEE("annualFee") }
enum class AnnualFeeBasis(val raw: String) {
    UNKNOWN("unknown"), FIXED_DATE("fixedDate"), OPENING_MONTH("openingMonth");
    companion object { fun from(raw: String) = entries.firstOrNull { it.raw == raw } ?: UNKNOWN }
}

data class CreditCardSettings(
    val repaymentRemind: Boolean = true,
    val repaymentLeadDays: Int = 1,
    val statementRemind: Boolean = false,
    val statementLeadDays: Int = 0,
    val annualFeeAmount: Double? = null,
    val annualFeeBasis: AnnualFeeBasis = AnnualFeeBasis.UNKNOWN,
    val annualFeeMonth: Int? = null,
    val annualFeeDay: Int? = null,
    val annualFeeWaiver: String = "",
    val annualFeeRemind: Boolean = false,
    val annualFeeLeadDays: Int = 30,
) {
    val isFeeWaivedOrFree: Boolean get() = annualFeeAmount == 0.0
}

data class CardReminder(
    val cardId: String, val kind: CardReminderKind, val dueDate: LocalDate,
    val remindAt: LocalDateTime, val scheduledAt: LocalDateTime,
    val createAfter: LocalDateTime, val cycle: String,
)

/** 1:1 对齐 iOS CreditCardPlan,纯 JVM 日期计算。 */
object CreditCardPlan {
    val monthlyLeadChoices = listOf(0, 1, 2, 3, 5, 7, 10, 15)
    val annualLeadChoices = listOf(0, 7, 15, 30, 60, 90)
    const val ANNUAL_CREATION_WINDOW_DAYS = 60L

    fun clampedLead(days: Int, kind: CardReminderKind) = days.coerceIn(0, if (kind == CardReminderKind.ANNUAL_FEE) 90 else 15)

    fun annualFeeRule(s: CreditCardSettings): Pair<Int, Int>? {
        val month = s.annualFeeMonth?.takeIf { it in 1..12 } ?: return null
        return when (s.annualFeeBasis) {
            AnnualFeeBasis.UNKNOWN -> null
            AnnualFeeBasis.OPENING_MONTH -> month to 1
            AnnualFeeBasis.FIXED_DATE -> s.annualFeeDay?.takeIf { it in 1..31 }?.let { month to it }
        }
    }

    fun isActive(card: FinanceSnapshot, kind: CardReminderKind): Boolean {
        if (card.kind != FinanceKind.CREDIT_CARD) return false
        val s = card.card
        return when (kind) {
            CardReminderKind.REPAYMENT -> s.repaymentRemind && card.dayOfMonth != null
            CardReminderKind.STATEMENT -> s.statementRemind && card.statementDay != null
            CardReminderKind.ANNUAL_FEE -> s.annualFeeRemind && !s.isFeeWaivedOrFree && annualFeeRule(s) != null
        }
    }

    fun nextAnnualFeeDate(s: CreditCardSettings, onOrAfter: LocalDate): LocalDate? {
        val (month, day) = annualFeeRule(s) ?: return null
        return (onOrAfter.year..onOrAfter.year + 1).map { y ->
            val ym = YearMonth.of(y, month)
            ym.atDay(minOf(day, ym.lengthOfMonth()))
        }.firstOrNull { !it.isBefore(onOrAfter) }
    }

    fun targetDate(card: FinanceSnapshot, kind: CardReminderKind, now: LocalDateTime): LocalDate? {
        if (card.kind != FinanceKind.CREDIT_CARD) return null
        return when (kind) {
            CardReminderKind.REPAYMENT -> FinancePlan.nextDueDate(card, now)
            CardReminderKind.STATEMENT -> FinancePlan.nextStatementDate(card, now)
            CardReminderKind.ANNUAL_FEE -> nextAnnualFeeDate(card.card, now.toLocalDate())
        }
    }

    fun reminder(card: FinanceSnapshot, kind: CardReminderKind, allDayTime: String, now: LocalDateTime): CardReminder? {
        val target = targetDate(card, kind, now) ?: return null
        val lead = when (kind) {
            CardReminderKind.REPAYMENT -> card.card.repaymentLeadDays
            CardReminderKind.STATEMENT -> card.card.statementLeadDays
            CardReminderKind.ANNUAL_FEE -> card.card.annualFeeLeadDays
        }
        val parts = allDayTime.split(":")
        val h = parts.getOrNull(0)?.toIntOrNull()
        val m = parts.getOrNull(1)?.toIntOrNull()
        val time = if (parts.size == 2 && h != null && m != null && h in 0..23 && m in 0..59) LocalTime.of(h, m) else LocalTime.of(9, 0)
        val at = target.minusDays(clampedLead(lead, kind).toLong()).atTime(time)
        return CardReminder(card.id, kind, target, maxOf(at, now), at,
            if (kind == CardReminderKind.ANNUAL_FEE) at.minusDays(ANNUAL_CREATION_WINDOW_DAYS) else LocalDateTime.MIN,
            target.toString())
    }
}

/** 提醒对账的纯决策,把一次性去重/尊重手动改期也纳入离线回归。 */
object CardReminderReconcile {
    data class Existing(val uuid: String, val pending: Boolean, val title: String, val remindAt: LocalDateTime)
    enum class Action { NONE, REMOVE, RENAME, RETIME, CREATE }
    data class Decision(val action: Action, val clearMark: Boolean = false, val setCycle: Boolean = false)

    fun decide(active: Boolean, reminder: CardReminder?, cycle: String, existing: Existing?,
               title: String, edited: Boolean, now: LocalDateTime): Decision {
        if (!active || reminder == null) return Decision(
            if (existing?.pending == true) Action.REMOVE else Action.NONE, clearMark = true)
        if (cycle == reminder.cycle) {
            if (existing?.pending != true) return Decision(Action.NONE) // 已完成或手动删了,同一期不补建。
            if (edited && existing.remindAt > now && existing.remindAt != reminder.remindAt) return Decision(Action.RETIME)
            return Decision(if (existing.title != title) Action.RENAME else Action.NONE)
        }
        if (now < reminder.createAfter) {
            return if (edited && existing?.pending == true && existing.remindAt > now) Decision(Action.REMOVE, clearMark = true)
            else Decision(Action.NONE)
        }
        return Decision(if (existing?.pending == true && existing.remindAt > now) Action.RETIME else Action.CREATE, setCycle = true)
    }
}
