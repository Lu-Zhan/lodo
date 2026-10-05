package com.lodo.app.data

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

data class ImportResult(val taskCount: Int, val memoryCount: Int, val relationshipCount: Int, val otherCount: Int = 0)

/**
 * 全量备份导入/导出:待办 + 记忆(含资产/人脉)+ 人脉关系边打成一个 zip,
 * 里面一个 data.json,对应 iOS zip 全量备份的数据部分。不含:iOS 独有的
 * 原始文件(记忆的 pdf/image/file 附件、人脉头像——这一轮 Android 记忆系统
 * 本身也没有这部分文件存储,见 MemoryEntity 的注释)、定时任务(两端都明确
 * "定时任务不进备份 zip",按产品约定如此,不是能力缺失——Android 的定时
 * 任务见 RoutineEntity/RoutineCheckWorker)。
 */
object Backup {
    private const val ENTRY_NAME = "data.json"

    suspend fun export(context: Context, uri: Uri, db: LodoDatabase) {
        val tasks = db.taskDao().all()
        val memories = db.memoryDao().all()
        val relationships = db.contactRelationshipDao().all()
        val json = JSONObject()
            .put("version", 3)
            .put("tasks", JSONArray(tasks.map { it.toJson() }))
            .put("memories", JSONArray(memories.map { it.toJson() }))
            .put("contactRelationships", JSONArray(relationships.map(::relationshipToJson)))
            // v3 起(对齐 iOS):倒数日、收入/支出/信用卡、旅行与行李清单、菜品、新闻订阅。
            // 文章不进备份(随时能重抓),AI 对话也不进(同 iOS)。
            .put("countdownEvents", JSONArray(db.countdownDao().all().map { it.toJson() }))
            .put("financeEntries", JSONArray(db.financeDao().all().map { it.toJson() }))
            .put("travelTrips", JSONArray(db.tripDao().all().map { it.toJson() }))
            .put("packingItems", JSONArray(db.tripDao().allPacking().map { it.toJson() }))
            .put("menuDishes", JSONArray(db.menuDao().allDishes().map { it.toJson() }))
            .put("newsFeeds", JSONArray(db.newsDao().feeds().map { it.toJson() }))
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
        val existingRelationshipUuids = db.contactRelationshipDao().all().map { it.uuid }.toSet()

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
        var relationshipCount = 0
        // 老版本备份(version 1)没有这个字段,optJSONArray 在缺失时返回 null,
        // 自然跳过,不影响老备份的其余部分正常导入。
        json.optJSONArray("contactRelationships")?.let { arr ->
            for (i in 0 until arr.length()) {
                val relationship = relationshipFromJson(arr.getJSONObject(i))
                if (relationship.uuid !in existingRelationshipUuids) {
                    db.contactRelationshipDao().upsert(relationship)
                    relationshipCount++
                }
            }
        }
        var otherCount = 0
        suspend fun <T> merge(key: String, parse: (JSONObject) -> T, uuid: (T) -> String, existing: Set<String>, save: suspend (T) -> Unit) {
            val arr = json.optJSONArray(key) ?: return
            for (i in 0 until arr.length()) {
                val item = parse(arr.getJSONObject(i))
                if (uuid(item) !in existing) { save(item); otherCount++ }
            }
        }
        merge("countdownEvents", ::countdownFromJson, { it.uuid }, db.countdownDao().all().map { it.uuid }.toSet()) { db.countdownDao().upsert(it) }
        merge("financeEntries", ::financeFromJson, { it.uuid }, db.financeDao().all().map { it.uuid }.toSet()) { db.financeDao().upsert(it) }
        merge("travelTrips", ::tripFromJson, { it.uuid }, db.tripDao().all().map { it.uuid }.toSet()) { db.tripDao().upsert(it) }
        merge("packingItems", ::packingFromJson, { it.uuid }, db.tripDao().allPacking().map { it.uuid }.toSet()) { db.tripDao().upsertPacking(it) }
        merge("menuDishes", ::menuDishFromJson, { it.uuid }, db.menuDao().allDishes().map { it.uuid }.toSet()) { db.menuDao().upsert(it) }
        merge("newsFeeds", ::newsFeedFromJson, { it.uuid }, db.newsDao().feeds().map { it.uuid }.toSet()) { db.newsDao().upsertFeed(it) }
        return ImportResult(taskCount, memoryCount, relationshipCount, otherCount)
    }

    private fun relationshipToJson(r: ContactRelationshipEntity) = JSONObject()
        .put("uuid", r.uuid).put("fromUuid", r.fromUuid).put("toUuid", r.toUuid).put("label", r.label)

    private fun relationshipFromJson(o: JSONObject) = ContactRelationshipEntity(
        uuid = o.getString("uuid"), fromUuid = o.getString("fromUuid"),
        toUuid = o.getString("toUuid"), label = o.getString("label"),
    )

}
