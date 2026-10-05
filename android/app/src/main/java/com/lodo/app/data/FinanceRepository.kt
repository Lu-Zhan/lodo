package com.lodo.app.data

import android.content.Context
import com.lodo.app.ai.ParsedTask
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

fun FinanceEntity.snapshot() = FinanceSnapshot(
    id = uuid, kind = FinanceKind.from(kind), title = title, amount = amount, currency = currency,
    cadence = FinanceCadence.from(cadence), dayOfMonth = dayOfMonth, statementDay = statementDay,
    institution = institution, endDate = endDateMillis?.toLocalDateTime(),
)

/** 收入/固定支出/信用卡 + 信用卡还款提醒,对应 iOS FinanceEntry + FinanceReminders。 */
class FinanceRepository(private val context: Context, private val db: LodoDatabase) {
    private val dao get() = db.financeDao()

    fun observeAll() = dao.observeAll()
    suspend fun all() = dao.all()

    suspend fun save(entry: FinanceEntity, tasks: TaskRepository, allDayTime: String) {
        dao.upsert(entry.copy(updatedAtMillis = System.currentTimeMillis()))
        syncReminders(tasks, allDayTime)
    }

    suspend fun delete(uuid: String, tasks: TaskRepository) {
        val e = dao.byUuid(uuid) ?: return
        removeReminderTask(e, tasks)
        dao.delete(uuid)
    }

    private suspend fun removeReminderTask(e: FinanceEntity, tasks: TaskRepository) {
        val taskUuid = e.reminderTaskUuid ?: return
        val task = tasks.current(taskUuid)
        if (task != null && task.statusEnum == TaskStatus.PENDING) tasks.delete(taskUuid)
    }

    /**
     * 开了提醒的卡:下一期还款日前一天的全天提醒时刻生成一条普通任务「还信用卡:银行 卡名」,
     * 任务提前建好、到时候才响;每张卡只追"下一期",防重复靠 reminderCycle/reminderTaskUuid;
     * 改了还款日时原地改那条还没响的任务;关提醒/删卡撤掉还没完成的那条(同 iOS)。
     */
    suspend fun syncReminders(tasks: TaskRepository, allDayTime: String) {
        val now = LocalDateTime.now()
        for (card in dao.all().filter { it.kind == FinanceKind.CREDIT_CARD.raw }) {
            if (!card.remindEnabled || card.dayOfMonth == null) {
                if (card.reminderTaskUuid != null) {
                    removeReminderTask(card, tasks)
                    dao.upsert(card.copy(reminderTaskUuid = null, reminderCycle = ""))
                }
                continue
            }
            val reminder = FinancePlan.reminder(card.snapshot(), allDayTime, now) ?: continue
            val title = L("还信用卡:", "Pay card: ") + listOf(card.institution, card.title).filter { it.isNotBlank() }.joinToString(" ")
            val existing = card.reminderTaskUuid?.let { tasks.current(it) }
            if (card.reminderCycle == reminder.cycle && existing != null) {
                if (existing.statusEnum == TaskStatus.PENDING && existing.title != title) {
                    tasks.applyEdit(existing.uuid, existing.toParsedTask().copy(title = title))
                }
                continue
            }
            val parsed = ParsedTask(title, reminder.remindAt, false, 0, RepeatType.NONE, emptyList(), emptyList())
            if (existing != null && existing.statusEnum == TaskStatus.PENDING) {
                tasks.applyEdit(existing.uuid, parsed)
                dao.upsert(card.copy(reminderCycle = reminder.cycle))
            } else {
                val created = tasks.saveNew(parsed)
                dao.upsert(card.copy(reminderCycle = reminder.cycle, reminderTaskUuid = created.uuid))
            }
        }
    }
}
