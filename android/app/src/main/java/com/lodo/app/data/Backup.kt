package com.lodo.app.data

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

data class ImportResult(val taskCount: Int, val memoryCount: Int)

/**
 * 全量备份导入/导出:待办 + 记忆(含资产/人脉)打成一个 zip,里面一个
 * data.json,对应 iOS zip 全量备份的数据部分。不含:iOS 独有的原始文件
 * (记忆的 pdf/image/file 附件、人脉头像——这一轮 Android 记忆系统本身也没有
 * 这部分文件存储,见 MemoryEntity 的注释)、定时任务(iOS 也明确"定时任务
 * 不进备份 zip",换设备靠各自的同步机制,Android 目前也没有定时任务功能)。
 */
object Backup {
    private const val ENTRY_NAME = "data.json"

    suspend fun export(context: Context, uri: Uri, db: LodoDatabase) {
        val tasks = db.taskDao().all()
        val memories = db.memoryDao().all()
        val json = JSONObject()
            .put("version", 1)
            .put("tasks", JSONArray(tasks.map(::taskToJson)))
            .put("memories", JSONArray(memories.map(::memoryToJson)))
        val out = context.contentResolver.openOutputStream(uri)
            ?: throw IllegalStateException("无法打开导出文件")
        out.use { stream ->
            ZipOutputStream(stream).use { zip ->
                zip.putNextEntry(ZipEntry(ENTRY_NAME))
                zip.write(json.toString().toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
    }

    /** 导入是"合并"不是"覆盖"——uuid 已存在的记录跳过(不覆盖本机可能更新过
     * 的数据),只补本机没有的,和大多数用户对"导入备份"的直觉预期一致
     * (不会因为误导入一份旧备份丢掉最近的修改)。 */
    suspend fun import(context: Context, uri: Uri, db: LodoDatabase): ImportResult {
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("无法打开备份文件")
        val text = input.use { stream ->
            ZipInputStream(stream).use { zip ->
                var entry = zip.nextEntry
                var content: String? = null
                while (entry != null) {
                    if (entry.name == ENTRY_NAME) {
                        content = zip.bufferedReader(Charsets.UTF_8).readText()
                        break
                    }
                    entry = zip.nextEntry
                }
                content
            }
        } ?: throw IllegalStateException("无效的备份文件:找不到 $ENTRY_NAME")

        val json = JSONObject(text)
        val existingTaskUuids = db.taskDao().all().map { it.uuid }.toSet()
        val existingMemoryUuids = db.memoryDao().all().map { it.uuid }.toSet()

        var taskCount = 0
        json.optJSONArray("tasks")?.let { arr ->
            for (i in 0 until arr.length()) {
                val task = taskFromJson(arr.getJSONObject(i))
                if (task.uuid !in existingTaskUuids) {
                    db.taskDao().upsert(task)
                    taskCount++
                }
            }
        }
        var memoryCount = 0
        json.optJSONArray("memories")?.let { arr ->
            for (i in 0 until arr.length()) {
                val memory = memoryFromJson(arr.getJSONObject(i))
                if (memory.uuid !in existingMemoryUuids) {
                    db.memoryDao().upsert(memory)
                    memoryCount++
                }
            }
        }
        return ImportResult(taskCount, memoryCount)
    }

    private fun taskToJson(t: TaskEntity) = JSONObject()
        .put("uuid", t.uuid).put("title", t.title)
        .put("remindAtMillis", t.remindAtMillis).put("durationMinutes", t.durationMinutes)
        .put("allDay", t.allDay).put("repeatType", t.repeatType)
        .put("repeatDays", t.repeatDays).put("repeatTimes", t.repeatTimes)
        .put("status", t.status).put("phase", t.phase)
        .put("nextRemindAtMillis", t.nextRemindAtMillis).put("createdAtMillis", t.createdAtMillis)
        .put("doneAtMillis", t.doneAtMillis ?: JSONObject.NULL)

    private fun taskFromJson(o: JSONObject) = TaskEntity(
        uuid = o.getString("uuid"), title = o.getString("title"),
        remindAtMillis = o.getLong("remindAtMillis"), durationMinutes = o.getInt("durationMinutes"),
        allDay = o.getBoolean("allDay"), repeatType = o.getString("repeatType"),
        repeatDays = o.getString("repeatDays"), repeatTimes = o.getString("repeatTimes"),
        status = o.getString("status"), phase = o.getString("phase"),
        nextRemindAtMillis = o.getLong("nextRemindAtMillis"),
        createdAtMillis = o.optLong("createdAtMillis", o.getLong("remindAtMillis")),
        doneAtMillis = o.longOrNull("doneAtMillis"),
    )

    private fun memoryToJson(m: MemoryEntity) = JSONObject()
        .put("uuid", m.uuid).put("kind", m.kind).put("title", m.title).put("summary", m.summary)
        .put("tags", m.tags).put("sourceText", m.sourceText)
        .put("urlString", m.urlString ?: JSONObject.NULL)
        .put("status", m.status).put("createdAtMillis", m.createdAtMillis)
        .put("assetValue", m.assetValue ?: JSONObject.NULL)
        .put("assetCurrency", m.assetCurrency ?: JSONObject.NULL)
        .put("assetLiability", m.assetLiability ?: JSONObject.NULL)
        .put("assetInterestRate", m.assetInterestRate ?: JSONObject.NULL)
        .put("contactNickname", m.contactNickname ?: JSONObject.NULL)
        .put("contactPhone", m.contactPhone ?: JSONObject.NULL)
        .put("contactEmail", m.contactEmail ?: JSONObject.NULL)
        .put("contactBirthdayMillis", m.contactBirthdayMillis ?: JSONObject.NULL)
        .put("contactPreferences", m.contactPreferences ?: JSONObject.NULL)

    private fun memoryFromJson(o: JSONObject) = MemoryEntity(
        uuid = o.getString("uuid"), kind = o.getString("kind"), title = o.getString("title"),
        summary = o.getString("summary"), tags = o.getString("tags"), sourceText = o.getString("sourceText"),
        urlString = o.stringOrNull("urlString"), status = o.getString("status"),
        createdAtMillis = o.getLong("createdAtMillis"),
        assetValue = o.doubleOrNull("assetValue"), assetCurrency = o.stringOrNull("assetCurrency"),
        assetLiability = o.doubleOrNull("assetLiability"), assetInterestRate = o.doubleOrNull("assetInterestRate"),
        contactNickname = o.stringOrNull("contactNickname"), contactPhone = o.stringOrNull("contactPhone"),
        contactEmail = o.stringOrNull("contactEmail"), contactBirthdayMillis = o.longOrNull("contactBirthdayMillis"),
        contactPreferences = o.stringOrNull("contactPreferences"),
    )

    private fun JSONObject.stringOrNull(key: String): String? =
        if (!has(key) || isNull(key)) null else getString(key)

    private fun JSONObject.doubleOrNull(key: String): Double? =
        if (!has(key) || isNull(key)) null else getDouble(key)

    private fun JSONObject.longOrNull(key: String): Long? =
        if (!has(key) || isNull(key)) null else getLong(key)
}
