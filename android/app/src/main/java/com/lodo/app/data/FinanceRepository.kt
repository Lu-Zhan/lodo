package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.ParsedTask
import androidx.room.withTransaction
import com.lodo.app.core.AnnualFeeBasis
import com.lodo.app.core.CardReminderKind
import com.lodo.app.core.CardReminderReconcile
import com.lodo.app.core.CreditCardPlan
import com.lodo.app.core.CreditCardSettings
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.lodo.app.core.FinanceCadence
import com.lodo.app.core.FinanceKind
import com.lodo.app.core.FinancePlan
import com.lodo.app.core.FinanceSnapshot
import com.lodo.app.core.RepeatType
import com.lodo.app.core.TaskStatus
import com.lodo.app.ui.L
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.time.LocalDateTime
import java.util.concurrent.TimeUnit

/**
 * 免费公开汇率(Frankfurter,基于 ECB 每日参考汇率,不要 key),同 iOS ExchangeRateStore:
 * 缓存一天,同币种恒等,换不出来返回 null 让调用方如实说明(不默默当 0)。
 */
object ExchangeRates {
    private const val ENDPOINT = "https://api.frankfurter.dev/v1/latest?base=USD"
    private val client = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()

    /** 1 USD = rates[code] code。 */
    val rates = MutableStateFlow<Map<String, Double>?>(null)
    private var fetchedAt = 0L

    fun load(context: Context) {
        if (rates.value != null) return
        val prefs = context.getSharedPreferences("exchange-rates", 0)
        val json = prefs.getString("table", null) ?: return
        fetchedAt = prefs.getLong("fetchedAt", 0)
        rates.value = runCatching { parse(JSONObject(json)) }.getOrNull()
    }

    private fun parse(o: JSONObject): Map<String, Double> {
        val r = o.getJSONObject("rates")
        return r.keys().asSequence().associateWith { r.getDouble(it) } + ("USD" to 1.0)
    }

    suspend fun refreshIfNeeded(context: Context) = withContext(Dispatchers.IO) {
        load(context)
        if (rates.value != null && System.currentTimeMillis() - fetchedAt < 24 * 3600_000L) return@withContext
        runCatching {
            client.newCall(Request.Builder().url(ENDPOINT).build()).execute().use { resp ->
                if (resp.code != 200) return@use
                val text = resp.body?.string() ?: return@use
                rates.value = parse(JSONObject(text))
                fetchedAt = System.currentTimeMillis()
                context.getSharedPreferences("exchange-rates", 0).edit()
                    .putString("table", text).putLong("fetchedAt", fetchedAt).apply()
            }
        }
    }

    fun convert(amount: Double, from: String, to: String): Double? {
        if (from == to) return amount
        val table = rates.value ?: return null
        val f = table[from.uppercase()] ?: return null
        val t = table[to.uppercase()] ?: return null
        return amount / f * t
    }

    val commonCurrencies = listOf("CNY", "USD", "EUR", "JPY", "HKD", "GBP", "KRW", "TWD", "SGD", "AUD", "CAD", "CHF", "THB")
}

val FinanceEntity.cardSettings get() = CreditCardSettings(
    repaymentRemind = remindEnabled, repaymentLeadDays = repaymentLeadDays,
    statementRemind = statementRemindEnabled, statementLeadDays = statementLeadDays,
    annualFeeAmount = annualFeeAmount, annualFeeBasis = AnnualFeeBasis.from(annualFeeBasisRaw),
    annualFeeMonth = annualFeeMonth, annualFeeDay = annualFeeDay, annualFeeWaiver = annualFeeWaiver,
    annualFeeRemind = annualFeeRemindEnabled, annualFeeLeadDays = annualFeeLeadDays,
)

fun FinanceEntity.snapshot() = FinanceSnapshot(
    id = uuid, kind = FinanceKind.from(kind), title = title, amount = amount, currency = currency,
    cadence = FinanceCadence.from(cadence), dayOfMonth = dayOfMonth, statementDay = statementDay,
    institution = institution, endDate = endDateMillis?.toLocalDateTime(), estimated = estimated, card = cardSettings,
)

fun FinanceEntity.reminderMark(kind: CardReminderKind): Pair<String, String?> = when (kind) {
    CardReminderKind.REPAYMENT -> reminderCycle to reminderTaskUuid
    CardReminderKind.STATEMENT -> statementReminderCycle to statementReminderTaskUuid
    CardReminderKind.ANNUAL_FEE -> annualFeeReminderCycle to annualFeeReminderTaskUuid
}

fun FinanceEntity.withReminderMark(kind: CardReminderKind, cycle: String, taskUuid: String?): FinanceEntity = when (kind) {
    CardReminderKind.REPAYMENT -> copy(reminderCycle = cycle, reminderTaskUuid = taskUuid)
    CardReminderKind.STATEMENT -> copy(statementReminderCycle = cycle, statementReminderTaskUuid = taskUuid)
    CardReminderKind.ANNUAL_FEE -> copy(annualFeeReminderCycle = cycle, annualFeeReminderTaskUuid = taskUuid)
}

/** 与 iOS FinanceReminders 对齐。Mutex 防前台/表单/后台同时对账重复建任务。 */
class FinanceRepository(private val context: Context, private val db: LodoDatabase) {
    private val dao get() = db.financeDao()
    private val mutex = Mutex()
    fun observeAll() = dao.observeAll()
    suspend fun all() = dao.all()

    suspend fun save(entry: FinanceEntity, tasks: TaskRepository, allDayTime: String) = mutex.withLock {
        // UI 快照可能早于后台对账;保存资料不能覆盖刚写下的防重复标记。
        val latest = dao.byUuid(entry.uuid)
        var updated = entry.copy(updatedAtMillis = System.currentTimeMillis())
        if (latest != null) for (kind in CardReminderKind.entries) {
            val (cycle, uuid) = latest.reminderMark(kind)
            updated = updated.withReminderMark(kind, cycle, uuid)
        }
        dao.upsert(updated)
        syncLocked(tasks, allDayTime, setOf(entry.uuid), LocalDateTime.now())
    }

    suspend fun delete(uuid: String, tasks: TaskRepository) = mutex.withLock {
        val card = dao.byUuid(uuid) ?: return@withLock
        for (kind in CardReminderKind.entries) card.reminderMark(kind).second?.let { id ->
            if (tasks.current(id)?.statusEnum == TaskStatus.PENDING) tasks.delete(id)
        }
        dao.delete(uuid)
    }

    suspend fun syncReminders(tasks: TaskRepository, allDayTime: String) = mutex.withLock {
        syncLocked(tasks, allDayTime, emptySet(), LocalDateTime.now())
    }

    private suspend fun syncLocked(tasks: TaskRepository, allDayTime: String, edited: Set<String>, now: LocalDateTime) {
        for (id in dao.all().filter { it.kind == FinanceKind.CREDIT_CARD.raw }.map { it.uuid }) {
            for (kind in CardReminderKind.entries) db.withTransaction {
                val card = dao.byUuid(id) ?: return@withTransaction
                val (cycle, taskId) = card.reminderMark(kind)
                val existing = taskId?.let { tasks.current(it) }
                val snapshot = card.snapshot()
                val reminder = CreditCardPlan.reminder(snapshot, kind, allDayTime, now)
                val title = taskTitle(card, kind)
                val decision = CardReminderReconcile.decide(CreditCardPlan.isActive(snapshot, kind), reminder, cycle,
                    existing?.let { CardReminderReconcile.Existing(it.uuid, it.statusEnum == TaskStatus.PENDING, it.title, it.remindAt) },
                    title, id in edited, now)
                var nextId = taskId
                when (decision.action) {
                    CardReminderReconcile.Action.NONE -> Unit
                    CardReminderReconcile.Action.REMOVE -> existing?.let { tasks.delete(it.uuid) }
                    CardReminderReconcile.Action.RENAME -> existing?.let { tasks.renamePending(it.uuid, title) }
                    CardReminderReconcile.Action.RETIME -> existing?.let { tasks.applyEdit(it.uuid, parsed(title, reminder!!.remindAt)) }
                    CardReminderReconcile.Action.CREATE -> { nextId = tasks.saveNew(parsed(title, reminder!!.remindAt)).uuid }
                }
                when {
                    decision.clearMark -> dao.upsert(card.withReminderMark(kind, "", null))
                    decision.setCycle -> dao.upsert(card.withReminderMark(kind, reminder!!.cycle, nextId))
                }
            }
        }
    }

    private fun parsed(title: String, at: LocalDateTime) = ParsedTask(title, at, false, 0, RepeatType.NONE, emptyList(), emptyList())

    private fun taskTitle(card: FinanceEntity, kind: CardReminderKind): String {
        val names = mutableListOf<String>()
        for (name in listOf(card.institution.trim(), card.title.trim()).filter { it.isNotEmpty() }) {
            if (names.none { it.contains(name) || name.contains(it) }) names += name
        }
        val prefix = when (kind) {
            CardReminderKind.REPAYMENT -> L("还信用卡:", "Pay card: ")
            CardReminderKind.STATEMENT -> L("查看信用卡账单:", "Check card statement: ")
            CardReminderKind.ANNUAL_FEE -> L("核对信用卡年费:", "Review card annual fee: ")
        }
        return prefix + names.joinToString(" ")
    }
}
