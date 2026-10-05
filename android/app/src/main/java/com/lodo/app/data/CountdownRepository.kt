package com.lodo.app.data

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.lodo.app.LodoApp
import com.lodo.app.MainActivity
import com.lodo.app.R
import com.lodo.app.ai.CountdownChange
import com.lodo.app.ai.CountdownDraft
import com.lodo.app.ai.CountdownOp
import com.lodo.app.core.CountdownEntry
import com.lodo.app.core.CountdownPlan
import com.lodo.app.notify.NotificationPermission
import com.lodo.app.notify.Notifications
import com.lodo.app.ui.L
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

fun CountdownEntity.entry() = CountdownEntry(
    id = uuid, title = title, start = startMillis.toLocalDateTime(), end = endMillis?.toLocalDateTime(),
    allDay = allDay, startReminders = startReminderList, endReminders = endReminderList,
    showInWidget = showInWidget, archived = archived,
)

/** 一次 AI 倒数日操作的记录:卡片据此列出改了什么,撤销也靠它(同 iOS CountdownEditRecord)。 */
data class CountdownEditRecord(
    val created: List<CountdownEntity> = emptyList(),
    val updatedBefore: List<CountdownEntity> = emptyList(),
    val updatedAfter: List<CountdownEntity> = emptyList(),
    val deleted: List<CountdownEntity> = emptyList(),
    val skipped: List<String> = emptyList(),
    val reverted: Boolean = false,
) {
    val hasChanges get() = created.isNotEmpty() || updatedAfter.isNotEmpty() || deleted.isNotEmpty()

    /** 喂回给模型的纯文字版,固定中文。 */
    val transcript: String
        get() {
            fun line(e: CountdownEntity): String {
                val f = DateTimeFormatter.ofPattern(if (e.allDay) "yyyy-MM-dd" else "yyyy-MM-dd HH:mm")
                return "「${e.title}」${e.startMillis.toLocalDateTime().format(f)}" +
                    (e.endMillis?.let { " 至 ${it.toLocalDateTime().format(f)}" } ?: "")
            }
            val parts = mutableListOf<String>()
            if (created.isNotEmpty()) parts += "新建倒数日:" + created.joinToString("、", transform = ::line)
            if (updatedAfter.isNotEmpty()) parts += "修改倒数日:" + updatedAfter.joinToString("、", transform = ::line)
            if (deleted.isNotEmpty()) parts += "删除倒数日:" + deleted.joinToString("、") { it.title }
            if (reverted) parts += "(已撤销)"
            return if (parts.isEmpty()) "倒数日没有改动。" else parts.joinToString(";")
        }

    fun toJson(): String = JSONObject()
        .put("created", JSONArray(created.map { it.toJson() }))
        .put("updatedBefore", JSONArray(updatedBefore.map { it.toJson() }))
        .put("updatedAfter", JSONArray(updatedAfter.map { it.toJson() }))
        .put("deleted", JSONArray(deleted.map { it.toJson() }))
        .put("skipped", JSONArray(skipped)).put("reverted", reverted).toString()

    companion object {
        fun decode(json: String?): CountdownEditRecord? = json?.let {
            runCatching {
                val o = JSONObject(it)
                fun list(k: String) = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { i -> countdownFromJson(a.getJSONObject(i)) } } ?: emptyList()
                CountdownEditRecord(list("created"), list("updatedBefore"), list("updatedAfter"), list("deleted"),
                    o.optJSONArray("skipped")?.let { a -> (0 until a.length()).map { i -> a.optString(i) } } ?: emptyList(),
                    o.optBoolean("reverted"))
            }.getOrNull()
        }
    }
}

fun CountdownEntity.toJson(): JSONObject = JSONObject().put("uuid", uuid).put("title", title)
    .put("startMillis", startMillis).put("endMillis", endMillis ?: JSONObject.NULL).put("allDay", allDay)
    .put("notes", notes).put("startReminders", startReminders).put("endReminders", endReminders)
    .put("showInWidget", showInWidget).put("archived", archived).put("createdAtMillis", createdAtMillis)

fun countdownFromJson(o: JSONObject) = CountdownEntity(
    uuid = o.getString("uuid"), title = o.optString("title"), startMillis = o.getLong("startMillis"),
    endMillis = if (o.isNull("endMillis")) null else o.optLong("endMillis"), allDay = o.optBoolean("allDay", true),
    notes = o.optString("notes"), startReminders = o.optString("startReminders"), endReminders = o.optString("endReminders"),
    showInWidget = o.optBoolean("showInWidget"), archived = o.optBoolean("archived"),
    createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
)

class CountdownRepository(private val context: Context, private val db: LodoDatabase) {
    private val dao get() = db.countdownDao()

    fun observeAll() = dao.observeAll()
    suspend fun all() = dao.all()

    suspend fun save(item: CountdownEntity) {
        dao.upsert(item)
        reschedule()
    }

    suspend fun delete(uuid: String) {
        dao.delete(uuid)
        reschedule()
    }

    suspend fun setArchived(uuid: String, archived: Boolean) {
        dao.byUuid(uuid)?.let { save(it.copy(archived = archived)) }
    }

    /** 执行 AI 的倒数日操作:直接生效,返回记录(带撤销快照)。小组件满 3 件时不放并如实记下。 */
    suspend fun apply(ops: List<CountdownOp>): CountdownEditRecord {
        val created = mutableListOf<CountdownEntity>()
        val before = mutableListOf<CountdownEntity>()
        val after = mutableListOf<CountdownEntity>()
        val deleted = mutableListOf<CountdownEntity>()
        val skipped = mutableListOf<String>()
        fun widgetCount() = (created + after).count { it.showInWidget && !it.archived }
        for (op in ops) {
            when (op) {
                is CountdownOp.Create -> {
                    val d: CountdownDraft = op.draft
                    var show = d.showInWidget == true
                    if (show && dao.all().count { it.showInWidget && !it.archived } + widgetCount() >= CountdownPlan.WIDGET_LIMIT) {
                        show = false
                        skipped += L("「${d.title}」没放上小组件(最多 3 件)", "\"${d.title}\" not added to widget (max 3)")
                    }
                    val e = CountdownEntity(
                        title = d.title, startMillis = d.start.toEpochMillis(), endMillis = d.end?.toEpochMillis(),
                        allDay = d.allDay, notes = d.notes, startReminders = joinIntCsv(d.startReminders),
                        endReminders = joinIntCsv(d.endReminders), showInWidget = show,
                    )
                    dao.upsert(e)
                    created += e
                }
                is CountdownOp.Update -> {
                    val old = dao.byUuid(op.id)
                    if (old == null) {
                        skipped += L("找不到要修改的倒数日", "Countdown not found"); continue
                    }
                    val c: CountdownChange = op.change
                    val updated = old.copy(
                        title = c.title ?: old.title,
                        startMillis = c.start?.toEpochMillis() ?: old.startMillis,
                        endMillis = if (c.clearEnd) null else c.end?.toEpochMillis() ?: old.endMillis,
                        allDay = c.allDay ?: old.allDay,
                        startReminders = c.startReminders?.let(::joinIntCsv) ?: old.startReminders,
                        endReminders = c.endReminders?.let(::joinIntCsv) ?: old.endReminders,
                        showInWidget = c.showInWidget ?: old.showInWidget,
                        notes = c.notes ?: old.notes,
                        archived = c.archived ?: old.archived,
                    )
                    dao.upsert(updated)
                    before += old
                    after += updated
                }
                is CountdownOp.Delete -> {
                    val old = dao.byUuid(op.id)
                    if (old == null) {
                        skipped += L("找不到要删除的倒数日", "Countdown not found"); continue
                    }
                    dao.delete(op.id)
                    deleted += old
                }
            }
        }
        reschedule()
        return CountdownEditRecord(created, before, after, deleted, skipped)
    }

    /** 撤销:新建的删掉,改过的/删掉的用快照写回。 */
    suspend fun revert(record: CountdownEditRecord) {
        record.created.forEach { dao.delete(it.uuid) }
        record.updatedBefore.forEach { dao.upsert(it) }
        record.deleted.forEach { dao.upsert(it) }
        reschedule()
    }

    /** 重排倒数日提醒:只排最近 20 条(AlarmManager 一个 app 最多 500 个闹钟,纠缠提醒还要用)。 */
    suspend fun reschedule() {
        val app = context.applicationContext as LodoApp
        val allDayTime = app.settings.snapshot().allDayTime
        val alarm = context.getSystemService(AlarmManager::class.java)
        val prefs = context.getSharedPreferences("countdown-alarms", 0)
        prefs.getStringSet("codes", emptySet())!!.forEach { code ->
            code.toIntOrNull()?.let { alarm.cancel(pending(it, null)) }
        }
        val reminders = CountdownPlan.reminders(dao.all().map { it.entry() }, allDayTime, LocalDateTime.now()).take(20)
        val codes = mutableSetOf<String>()
        reminders.forEach { r ->
            val code = ("countdown-" + r.eventId + r.isEnd + r.offsetMinutes).hashCode()
            codes += code.toString()
            val intent = pending(code, r)
            val at = r.fireAt.toEpochMillis()
            runCatching {
                if (alarm.canScheduleExactAlarms()) alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
                else alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            }
        }
        prefs.edit().putStringSet("codes", codes).apply()
    }

    private fun pending(code: Int, r: com.lodo.app.core.CountdownReminder?): PendingIntent {
        val intent = Intent(context, CountdownReceiver::class.java)
        if (r != null) {
            intent.putExtra("title", r.title).putExtra("isEnd", r.isEnd).putExtra("offset", r.offsetMinutes)
        }
        return PendingIntent.getBroadcast(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

/** 倒数日提醒到点:发一条通知(不纠缠,倒数日不需要完成)。 */
class CountdownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: return
        val isEnd = intent.getBooleanExtra("isEnd", false)
        val offset = intent.getIntExtra("offset", 0)
        if (NotificationPermission.isGranted(context)) {
            val body = when {
                offset == 0 && !isEnd -> L("就是今天/现在开始", "Starts now")
                offset == 0 -> L("现在结束", "Ends now")
                else -> {
                    val span = offsetLabel(offset)
                    if (isEnd) L("还有 $span 结束", "Ends in $span") else L("还有 $span 开始", "Starts in $span")
                }
            }
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).putExtra("route", "countdown"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val n = NotificationCompat.Builder(context, Notifications.CHANNEL_DIGEST)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title).setContentText(body).setContentIntent(open).setAutoCancel(true).build()
            runCatching { NotificationManagerCompat.from(context).notify(("cd" + title + isEnd + offset).hashCode(), n) }
        }
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            runCatching { (context.applicationContext as LodoApp).countdowns.reschedule() }
            pending.finish()
        }
    }
}

fun offsetLabel(minutes: Int): String = when {
    minutes % 10080 == 0 -> L("${minutes / 10080} 周", "${minutes / 10080} wk")
    minutes % 1440 == 0 -> L("${minutes / 1440} 天", "${minutes / 1440} d")
    minutes % 60 == 0 -> L("${minutes / 60} 小时", "${minutes / 60} h")
    else -> L("$minutes 分钟", "$minutes min")
}
