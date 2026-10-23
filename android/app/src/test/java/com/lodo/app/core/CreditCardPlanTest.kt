package com.lodo.app.core

import com.lodo.app.data.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime

/** 对齐 iOS CreditCardPlanTests;共享用例按用户要求不移植。 */
class CreditCardPlanTest {
    private fun date(y: Int, m: Int, d: Int, h: Int = 0, min: Int = 0) = LocalDateTime.of(y, m, d, h, min)
    private val now = date(2026, 7, 8, 9)
    private fun card(s: CreditCardSettings = CreditCardSettings(), due: Int? = 13, statement: Int? = 25) =
        FinanceSnapshot("card", FinanceKind.CREDIT_CARD, "招行", dayOfMonth = due, statementDay = statement, card = s)
    private fun reminder(s: CreditCardSettings = CreditCardSettings(), kind: CardReminderKind = CardReminderKind.REPAYMENT,
                         time: String = "09:00", at: LocalDateTime = now) = CreditCardPlan.reminder(card(s), kind, time, at)!!

    @Test fun defaultsKeepOldRepaymentBehaviour() {
        assertTrue(CreditCardPlan.isActive(card(), CardReminderKind.REPAYMENT))
        assertFalse(CreditCardPlan.isActive(card(), CardReminderKind.STATEMENT))
        assertFalse(CreditCardPlan.isActive(card(), CardReminderKind.ANNUAL_FEE))
        assertEquals(date(2026, 7, 13).toLocalDate(), reminder().dueDate)
        assertEquals(date(2026, 7, 12, 9), reminder().remindAt)
    }
    @Test fun statementAndRepaymentAcrossMonths() {
        val s = CreditCardSettings(statementRemind = true)
        assertEquals(LocalDate.of(2026, 8, 13), reminder(s, at = date(2026, 7, 20, 10)).dueDate)
        val stmt = reminder(s, CardReminderKind.STATEMENT, at = date(2026, 7, 20, 10))
        assertEquals(date(2026, 7, 25, 9), stmt.remindAt)
        assertEquals("2026-07-25", stmt.cycle)
    }
    @Test fun leadDaysAndPastTimeFiresNow() {
        val s = CreditCardSettings(repaymentLeadDays = 3)
        assertEquals(date(2026, 7, 10, 20, 30), reminder(s, time = "20:30").remindAt)
        val late = date(2026, 7, 11, 8)
        assertEquals(late, reminder(s, time = "20:30", at = late).remindAt)
        assertEquals(date(2026, 7, 10, 20, 30), reminder(s, time = "20:30", at = late).scheduledAt)
    }
    @Test fun leadDaysAreClamped() {
        assertEquals(date(2026, 6, 28, 9), reminder(CreditCardSettings(repaymentLeadDays = 40)).scheduledAt)
        assertEquals(0, CreditCardPlan.clampedLead(-1, CardReminderKind.STATEMENT))
        assertEquals(90, CreditCardPlan.clampedLead(200, CardReminderKind.ANNUAL_FEE))
    }
    @Test fun invalidAllDayTimeFallsBackToNine() {
        for (time in listOf("25:99", "bad", "09:", "09:30:00")) assertEquals(date(2026, 7, 12, 9), reminder(time = time).scheduledAt)
    }
    @Test fun annualFeeFixedDateAndLeap() {
        val leap = CreditCardSettings(annualFeeAmount = 480.0, annualFeeBasis = AnnualFeeBasis.FIXED_DATE,
            annualFeeMonth = 2, annualFeeDay = 29, annualFeeRemind = true)
        assertEquals(LocalDate.of(2027, 2, 28), CreditCardPlan.nextAnnualFeeDate(leap, now.toLocalDate()))
        assertEquals(LocalDate.of(2028, 2, 29), CreditCardPlan.nextAnnualFeeDate(leap, LocalDate.of(2027, 3, 1)))
        val r = reminder(leap.copy(annualFeeMonth = 11, annualFeeDay = 1), CardReminderKind.ANNUAL_FEE)
        assertEquals(date(2026, 10, 2, 9), r.scheduledAt)
        assertEquals(date(2026, 8, 3, 9), r.createAfter)
    }
    @Test fun annualFeeOpeningMonthUsesFirstDay() {
        val s = CreditCardSettings(annualFeeBasis = AnnualFeeBasis.OPENING_MONTH, annualFeeMonth = 3)
        assertEquals(LocalDate.of(2027, 3, 1), CreditCardPlan.nextAnnualFeeDate(s, now.toLocalDate()))
        assertEquals(LocalDate.of(2027, 3, 1), CreditCardPlan.nextAnnualFeeDate(s, LocalDate.of(2027, 3, 1)))
    }
    @Test fun annualFeeNotActiveWhenFreeOrUnknown() {
        val s = CreditCardSettings(annualFeeAmount = 0.0, annualFeeBasis = AnnualFeeBasis.FIXED_DATE,
            annualFeeMonth = 5, annualFeeDay = 1, annualFeeRemind = true)
        assertFalse(CreditCardPlan.isActive(card(s), CardReminderKind.ANNUAL_FEE))
        assertFalse(CreditCardPlan.isActive(card(s.copy(annualFeeAmount = 480.0, annualFeeBasis = AnnualFeeBasis.UNKNOWN)), CardReminderKind.ANNUAL_FEE))
        assertFalse(CreditCardPlan.isActive(card(s.copy(annualFeeAmount = 480.0, annualFeeDay = null)), CardReminderKind.ANNUAL_FEE))
        assertTrue(CreditCardPlan.isActive(card(s.copy(annualFeeAmount = null)), CardReminderKind.ANNUAL_FEE))
    }
    @Test fun statementInactiveWithoutDay() {
        val c = card(CreditCardSettings(statementRemind = true), statement = null)
        assertFalse(CreditCardPlan.isActive(c, CardReminderKind.STATEMENT))
        assertNull(CreditCardPlan.reminder(c, CardReminderKind.STATEMENT, "09:00", now))
    }
    @Test fun entrySettingsRoundTripAndBackup() {
        val e = FinanceEntity(kind = "creditCard", title = "招行", repaymentLeadDays = 3, statementRemindEnabled = true,
            annualFeeAmount = 480.0, annualFeeBasisRaw = "fixedDate", annualFeeMonth = 11, annualFeeDay = 1,
            annualFeeWaiver = "刷满 6 次", annualFeeRemindEnabled = true, annualFeeLeadDays = 15)
        assertEquals(e.cardSettings, financeFromJson(e.toJson()).cardSettings)
        val old = financeFromJson(JSONObject().put("uuid", "old").put("kind", "creditCard"))
        assertEquals(CreditCardSettings(), old.cardSettings)
    }
    @Test fun unknownBasisRawIsPreservedByBackup() {
        val e = FinanceEntity(kind = "creditCard", title = "招行", annualFeeBasisRaw = "anniversary")
        assertEquals("anniversary", financeFromJson(e.toJson()).annualFeeBasisRaw)
    }
    @Test fun reminderMarksPerKind() {
        val e = FinanceEntity(kind = "creditCard", title = "招行").withReminderMark(CardReminderKind.ANNUAL_FEE, "2026-11-01", "task")
        assertEquals("task", e.reminderMark(CardReminderKind.ANNUAL_FEE).second)
        assertNull(e.reminderMark(CardReminderKind.REPAYMENT).second)
        assertEquals("", e.reminderMark(CardReminderKind.STATEMENT).first)
        assertNull(financeFromJson(e.toJson()).annualFeeReminderTaskUuid)
    }
    @Test fun estimatedSpendingMonthlyAndAnnualFeesExcluded() {
        val entries = listOf(card(CreditCardSettings(annualFeeAmount = 480.0)),
            FinanceSnapshot("income", FinanceKind.INCOME, "工资", amount = 10000.0),
            FinanceSnapshot("spend", FinanceKind.EXPENSE, "吃饭", amount = 3000.0, estimated = true, cadence = FinanceCadence.YEARLY))
        val total = FinancePlan.monthlyTotal(entries, "CNY", now) { _, _, _ -> null }
        assertEquals(3000.0, total.spending, 0.001)
        assertEquals(0.0, total.expense, 0.001)
        assertEquals(7000.0, total.net, 0.001)
    }

    private fun decision(cycle: String = reminder().cycle, existing: CardReminderReconcile.Existing? = null, edited: Boolean = false,
                         r: CardReminder? = reminder(), active: Boolean = true) =
        CardReminderReconcile.decide(active, r, cycle, existing, "还信用卡:招行", edited, now)
    @Test fun deletedCurrentCycleIsNotRecreated() { assertEquals(CardReminderReconcile.Action.NONE, decision().action) }
    @Test fun completedCurrentCycleIsNotRecreated() {
        assertEquals(CardReminderReconcile.Action.NONE, decision(existing = CardReminderReconcile.Existing("id", false, "", now)).action)
    }
    @Test fun foregroundSyncPreservesManualReschedule() {
        val existing = CardReminderReconcile.Existing("id", true, "还信用卡:招行", now.plusDays(3))
        assertEquals(CardReminderReconcile.Action.NONE, decision(existing = existing).action)
        assertEquals(CardReminderReconcile.Action.RETIME, decision(existing = existing, edited = true).action)
    }
    @Test fun renameDoesNotResetReminderTime() {
        val existing = CardReminderReconcile.Existing("id", true, "旧卡名", now.minusDays(1))
        assertEquals(CardReminderReconcile.Action.RENAME, decision(existing = existing, edited = true).action)
    }
    @Test fun newCycleDoesNotOverwriteOverdueUnfinishedTask() {
        val existing = CardReminderReconcile.Existing("id", true, "还信用卡:招行", now.minusDays(1))
        assertEquals(CardReminderReconcile.Action.CREATE, decision("old-cycle", existing).action)
    }
    @Test fun disablingReminderRemovesOnlyPendingTask() {
        val existing = CardReminderReconcile.Existing("id", true, "", now.plusDays(1))
        assertEquals(CardReminderReconcile.Action.REMOVE, decision(existing = existing, active = false).action)
        assertEquals(CardReminderReconcile.Action.NONE, decision(existing = existing.copy(pending = false), active = false).action)
        assertTrue(decision(active = false).clearMark)
    }
    @Test fun annualFeeWaitsUntilCreationWindow() {
        val r = reminder(CreditCardSettings(annualFeeBasis = AnnualFeeBasis.FIXED_DATE, annualFeeMonth = 11, annualFeeDay = 1), CardReminderKind.ANNUAL_FEE)
        assertEquals(CardReminderReconcile.Action.NONE, decision(cycle = "", r = r).action)
        val old = CardReminderReconcile.Existing("id", true, "", now.plusDays(1))
        assertEquals(CardReminderReconcile.Action.REMOVE, decision("old", old, true, r).action)
    }
}
