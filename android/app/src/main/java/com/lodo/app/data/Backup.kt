package com.lodo.app.data

import android.content.Context
import android.net.Uri
import androidx.room.withTransaction
import com.lodo.app.core.MemoryFilePolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

data class ImportResult(val taskCount: Int, val memoryCount: Int, val relationshipCount: Int, val otherCount: Int = 0)

/** v4 起包含 Memory/ 原件。导入保留本机已有记录,全部 SQL 在同一事务中执行。
 * zip 先在私有临时目录校验/限量解包,绝不按不受信路径直接写应用目录。
 */
object Backup {
    private const val ENTRY_NAME = "data.json"

    suspend fun export(context: Context, uri: Uri, db: LodoDatabase) = withContext(Dispatchers.IO) {
        val snapshot = db.withTransaction {
            val memories = db.memoryDao().all()
            val json = JSONObject().put("version", 4)
                .put("tasks", JSONArray(db.taskDao().all().map { it.toJson() }))
                .put("memories", JSONArray(memories.map { it.toJson() }))
                .put("contactRelationships", JSONArray(db.contactRelationshipDao().all().map(::relationshipToJson)))
                .put("countdownEvents", JSONArray(db.countdownDao().all().map { it.toJson() }))
                .put("financeEntries", JSONArray(db.financeDao().all().map { it.toJson() }))
                .put("travelTrips", JSONArray(db.tripDao().all().map { it.toJson() }))
                .put("packingItems", JSONArray(db.tripDao().allPacking().map { it.toJson() }))
                .put("menuDishes", JSONArray(db.menuDao().allDishes().map { it.toJson() }))
                .put("newsFeeds", JSONArray(db.newsDao().feeds().map { it.toJson() }))
                .put("weightRecords", JSONArray(db.healthDao().weights().map { it.toJson() }))
                .put("foodRecords", JSONArray(db.healthDao().foods().map { it.toJson() }))
                .put("medications", JSONArray(db.healthDao().medications().map { it.toJson() }))
                .put("medicationDoses", JSONArray(db.healthDao().doses().map { it.toJson() }))
                .put("periodRecords", JSONArray(db.healthDao().periods().map { it.toJson() }))
                .put("periodFlowRecords", JSONArray(db.healthDao().flows().map { it.toJson() }))
                .put("healthProfiles", JSONArray(db.healthDao().profiles().map { it.toJson() }))
                .put("checkupEntries", JSONArray(db.healthDao().checkups().map { it.toJson() }))
                .put("healthSettings", (context.applicationContext as com.lodo.app.LodoApp).healthJournal.backupSettings())
            json to memories
        }
        val bytes = snapshot.first.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MemoryFilePolicy.MAX_JSON_BYTES) { "备份数据过大" }
        val files = MemoryFiles(context)
        val out = context.contentResolver.openOutputStream(uri) ?: error("无法打开导出文件")
        out.use { stream -> ZipOutputStream(stream).use { zip ->
            zip.putNextEntry(ZipEntry(ENTRY_NAME)); zip.write(bytes); zip.closeEntry()
            var total = bytes.size.toLong()
            for (relative in snapshot.second.mapNotNull { it.relativeFilePath }.distinct()) {
                val file = files.resolve(relative)?.takeIf { it.isFile } ?: continue
                zip.putNextEntry(ZipEntry(relative))
                file.inputStream().use { input ->
                    total += MemoryFilePolicy.copyLimited(input, zip, minOf(MemoryFilePolicy.MAX_FILE_BYTES, MemoryFilePolicy.MAX_BACKUP_BYTES - total))
                }
                zip.closeEntry()
            }
        } }
    }

    suspend fun import(context: Context, uri: Uri, db: LodoDatabase): ImportResult = withContext(Dispatchers.IO) {
        val staging = File(context.cacheDir, "restore-${UUID.randomUUID()}").apply { mkdirs() }
        val createdFiles = mutableListOf<File>()
        try {
            val input = context.contentResolver.openInputStream(uri) ?: error("无法打开备份文件")
            var jsonBytes: ByteArray? = null
            val names = mutableSetOf<String>()
            var total = 0L
            var entries = 0
            input.use { stream -> ZipInputStream(stream).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(++entries <= MemoryFilePolicy.MAX_ZIP_ENTRIES) { "备份条目过多" }
                    require(names.add(entry.name)) { "备份包含重复文件" }
                    require(!entry.name.startsWith('/') && entry.name.split('/', '\\').none { it == ".." }) { "备份路径无效" }
                    if (entry.isDirectory) { zip.closeEntry(); continue }
                    val remaining = MemoryFilePolicy.MAX_BACKUP_BYTES - total
                    when {
                        entry.name == ENTRY_NAME -> {
                            val bytes = ByteArrayOutputStream()
                            total += MemoryFilePolicy.copyLimited(zip, bytes, minOf(remaining, MemoryFilePolicy.MAX_JSON_BYTES))
                            jsonBytes = bytes.toByteArray()
                        }
                        MemoryFilePolicy.safePath(entry.name) -> {
                            val file = File(staging, entry.name).apply { parentFile!!.mkdirs() }
                            file.outputStream().use { output ->
                                total += MemoryFilePolicy.copyLimited(zip, output, minOf(remaining, MemoryFilePolicy.MAX_FILE_BYTES))
                            }
                        }
                        else -> {
                            val sink = object : OutputStream() {
                                override fun write(b: Int) = Unit
                                override fun write(b: ByteArray, off: Int, len: Int) = Unit
                            }
                            total += MemoryFilePolicy.copyLimited(zip, sink, minOf(remaining, MemoryFilePolicy.MAX_FILE_BYTES))
                        }
                    }
                    zip.closeEntry()
                }
            } }
            val json = JSONObject(jsonBytes?.toString(Charsets.UTF_8) ?: error("无效的备份文件:找不到 $ENTRY_NAME"))
            require(json.optInt("version", 1) in 1..4) { "备份版本过新,请先更新应用" }
            val files = MemoryFiles(context)
            val result = db.withTransaction {
                var taskCount = 0
                var memoryCount = 0
                var relationshipCount = 0
                var otherCount = 0
                val taskIds = db.taskDao().all().map { it.uuid }.toMutableSet()
                val memoryIds = db.memoryDao().all().map { it.uuid }.toMutableSet()
                val relationshipIds = db.contactRelationshipDao().all().map { it.uuid }.toMutableSet()
                json.optJSONArray("tasks")?.let { arr -> for (i in 0 until arr.length()) {
                    val item = taskFromJson(arr.getJSONObject(i))
                    if (taskIds.add(item.uuid)) { db.taskDao().upsert(item); taskCount++ }
                } }
                json.optJSONArray("memories")?.let { arr -> for (i in 0 until arr.length()) {
                    var item = memoryFromJson(arr.getJSONObject(i))
                    if (memoryIds.add(item.uuid)) {
                        item.relativeFilePath?.let { relative ->
                            require(MemoryFilePolicy.safePath(relative)) { "备份原文件路径无效" }
                            // 新路径避免不受信备份覆盖本机任何已存在的原件。
                            val newPath = "Memory/${UUID.randomUUID()}.${MemoryFilePolicy.extension(relative)}"
                            val original = File(staging, relative)
                            if (original.isFile) {
                                val target = files.resolve(newPath)!!.apply { parentFile!!.mkdirs() }
                                createdFiles += target
                                original.copyTo(target, overwrite = false)
                            }
                            item = item.copy(relativeFilePath = newPath)
                        }
                        db.memoryDao().upsert(item); memoryCount++
                    }
                } }
                json.optJSONArray("contactRelationships")?.let { arr -> for (i in 0 until arr.length()) {
                    val item = relationshipFromJson(arr.getJSONObject(i))
                    if (relationshipIds.add(item.uuid)) { db.contactRelationshipDao().upsert(item); relationshipCount++ }
                } }
                suspend fun <T> merge(key: String, parse: (JSONObject) -> T, uuid: (T) -> String, existing: Set<String>, save: suspend (T) -> Unit) {
                    val arr = json.optJSONArray(key) ?: return
                    val ids = existing.toMutableSet()
                    for (i in 0 until arr.length()) {
                        val item = parse(arr.getJSONObject(i))
                        validateHealthBackupRecord(item)
                        if (ids.add(uuid(item))) { save(item); otherCount++ }
                    }
                }
                merge("countdownEvents", ::countdownFromJson, { it.uuid }, db.countdownDao().all().map { it.uuid }.toSet()) { db.countdownDao().upsert(it) }
                merge("financeEntries", ::financeFromJson, { it.uuid }, db.financeDao().all().map { it.uuid }.toSet()) { db.financeDao().upsert(it) }
                merge("travelTrips", ::tripFromJson, { it.uuid }, db.tripDao().all().map { it.uuid }.toSet()) { db.tripDao().upsert(it) }
                merge("packingItems", ::packingFromJson, { it.uuid }, db.tripDao().allPacking().map { it.uuid }.toSet()) { db.tripDao().upsertPacking(it) }
                merge("menuDishes", ::menuDishFromJson, { it.uuid }, db.menuDao().allDishes().map { it.uuid }.toSet()) { db.menuDao().upsert(it) }
                merge("newsFeeds", ::newsFeedFromJson, { it.uuid }, db.newsDao().feeds().map { it.uuid }.toSet()) { db.newsDao().upsertFeed(it) }
                merge("weightRecords", ::weightFromJson, { it.uuid }, db.healthDao().weights().map { it.uuid }.toSet()) { db.healthDao().saveWeight(it) }
                merge("foodRecords", ::foodFromJson, { it.uuid }, db.healthDao().foods().map { it.uuid }.toSet()) { db.healthDao().saveFood(it) }
                merge("medications", ::medicationFromJson, { it.uuid }, db.healthDao().medications().map { it.uuid }.toSet()) { db.healthDao().saveMedication(it) }
                merge("medicationDoses", ::doseFromJson, { it.uuid }, db.healthDao().doses().map { it.uuid }.toSet()) { db.healthDao().saveDose(it) }
                merge("periodRecords", ::periodFromJson, { it.uuid }, db.healthDao().periods().map { it.uuid }.toSet()) { db.healthDao().savePeriod(it) }
                merge("periodFlowRecords", ::flowFromJson, { it.uuid }, db.healthDao().flows().map { it.uuid }.toSet()) { db.healthDao().saveFlow(it) }
                merge("healthProfiles", ::profileFromJson, { it.uuid }, db.healthDao().profiles().map { it.uuid }.toSet()) { db.healthDao().saveProfile(it) }
                merge("checkupEntries", ::checkupFromJson, { it.uuid }, db.healthDao().checkups().map { it.uuid }.toSet()) { db.healthDao().saveCheckup(it) }
                ImportResult(taskCount, memoryCount, relationshipCount, otherCount)
            }
            createdFiles.clear() // 已提交,原件归数据库拥有。
            json.optJSONObject("healthSettings")?.let { (context.applicationContext as com.lodo.app.LodoApp).healthJournal.restoreSettings(it) }
            result
        } finally {
            createdFiles.forEach { it.delete() }
            staging.deleteRecursively()
        }
    }

    private fun relationshipToJson(r: ContactRelationshipEntity) = JSONObject()
        .put("uuid", r.uuid).put("fromUuid", r.fromUuid).put("toUuid", r.toUuid).put("label", r.label)
    private fun relationshipFromJson(o: JSONObject) = ContactRelationshipEntity(
        uuid = o.getString("uuid"), fromUuid = o.getString("fromUuid"), toUuid = o.getString("toUuid"), label = o.getString("label"))
}
