package com.lodo.app.data

import androidx.room.withTransaction
import com.lodo.app.LodoApp
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.*
import java.time.LocalDate

fun CheckupEntryEntity.snapshot() = CheckupEntryValue(uuid, reportUuid, kind, category, name, value, unit, referenceRange, flag, conclusion, advice, LocalDate.parse(dateDay), sortIndex)
fun MemoryEntity.checkupOwner() = checkupProfileUuid ?: tagsList.firstOrNull { it.startsWith("health-profile:") }?.removePrefix("health-profile:")
data class CheckupReview(val profileId: String?, val before: List<CheckupEntryEntity>, val plan: CheckupNormalizationPlan)

/** 报告元数据与所有条目的冗余字段始终在一个事务里改;家人的数据不变成本人。 */
class CheckupRepository(private val app: LodoApp) {
    private val db get() = app.database
    private val dao get() = db.healthDao()
    companion object {
        const val TAG = "体检报告"
        const val RAW_MARKER = "\n\n——报告原文——\n"
        fun rawText(item: MemoryEntity) = item.sourceText.substringAfter(RAW_MARKER, item.sourceText)
    }
    private fun tags(owner: String?) = listOf(TAG) + if (owner == null) listOf(MemoryEntity.healthTagName) else listOf("家人健康", "health-profile:$owner")
    suspend fun saveParsed(source: MemoryEntity, parsed: ParsedCheckupReport) = db.withTransaction {
        val current = db.memoryDao().byUuid(source.uuid) ?: error("报告已删除,未写入整理结果")
        require(current.checkupOwner() == source.checkupOwner() && current.checkupDateDay == source.checkupDateDay && current.title == source.title && current.sourceText == source.sourceText) { "报告资料已改变,请重新整理" }
        require(parsed.items.isNotEmpty() || parsed.summaryAdvice.isNotBlank()) { "没有从这份报告里整理出任何指标。" }
        val owner = current.checkupOwner()
        val date = parsed.date ?: current.checkupDateDay?.let(LocalDate::parse) ?: LocalDate.now()
        dao.deleteReportEntries(current.uuid)
        parsed.items.forEachIndexed { index, item -> dao.saveCheckup(CheckupEntryEntity(reportUuid = current.uuid, profileUuid = owner,
            category = item.category, name = item.name, value = item.value, unit = item.unit, referenceRange = item.reference,
            flag = item.flag, conclusion = item.conclusion, advice = item.advice, dateDay = date.toString(), sortIndex = index)) }
        if (parsed.summaryAdvice.isNotBlank()) dao.saveCheckup(CheckupEntryEntity(reportUuid = current.uuid, profileUuid = owner, kind = "advice", advice = parsed.summaryAdvice, dateDay = date.toString(), sortIndex = parsed.items.size))
        db.memoryDao().upsert(current.copy(title = parsed.title.ifBlank { "体检报告 $date" }, checkupDateDay = date.toString(), checkupProfileUuid = owner,
            checkupInstitution = parsed.institution.takeIf { it.isNotBlank() }, tags = joinCsv(tags(owner)), sourceText = RAW_MARKER + rawText(source), status = MemoryStatus.READY.raw))
        refreshDerived(current.uuid)
    }
    suspend fun updateReport(id: String, title: String, date: LocalDate, institution: String, owner: String?) = db.withTransaction {
        val report = db.memoryDao().byUuid(id) ?: error("报告已删除")
        require(owner == null || dao.profiles().any { it.uuid == owner }) { "家人档案已删除" }
        val others = report.tagsList.filter { it !in setOf(TAG, MemoryEntity.healthTagName, "家人健康") && !it.startsWith("health-profile:") }
        db.memoryDao().upsert(report.copy(title = title.trim().ifBlank { "体检报告 $date" }, checkupDateDay = date.toString(), checkupInstitution = institution.trim().takeIf { it.isNotBlank() },
            checkupProfileUuid = owner, tags = joinCsv((tags(owner) + others).distinct())))
        dao.checkups().filter { it.reportUuid == id }.forEach { dao.saveCheckup(it.copy(profileUuid = owner, dateDay = date.toString())) }
        refreshDerived(id)
    }
    suspend fun saveEntry(entry: CheckupEntryEntity) = db.withTransaction {
        validateHealthBackupRecord(entry)
        val report = db.memoryDao().byUuid(entry.reportUuid)
        if (report == null) {
            require(entry.profileUuid == null || dao.profiles().any { it.uuid == entry.profileUuid }) { "家人档案已删除" }
            db.memoryDao().upsert(MemoryEntity.create(MemoryKind.TEXT, title = "体检记录 ${entry.dateDay}", tags = tags(entry.profileUuid), status = MemoryStatus.READY)
                .copy(uuid = entry.reportUuid, checkupDateDay = entry.dateDay, checkupProfileUuid = entry.profileUuid))
        } else {
            require(entry.profileUuid == report.checkupOwner() && entry.dateDay == (report.checkupDateDay ?: entry.dateDay)) { "请在报告资料中统一修改日期和归属" }
        }
        dao.saveCheckup(entry); refreshDerived(entry.reportUuid)
    }
    suspend fun deleteEntry(id: String) = db.withTransaction {
        val entry = dao.checkups().firstOrNull { it.uuid == id } ?: return@withTransaction
        dao.deleteCheckup(id); refreshDerived(entry.reportUuid)
    }
    suspend fun refreshDerived(id: String) {
        val report = db.memoryDao().byUuid(id) ?: return
        val entries = dao.checkups().filter { it.reportUuid == id }.sortedBy { it.sortIndex }
        val lines = entries.map { e -> if (e.kind == "item") listOf(e.category, e.name, e.snapshot().displayValue, e.referenceRange.takeIf { it.isNotBlank() }?.let { "参考 $it" }.orEmpty(), e.conclusion, e.advice).filter { it.isNotBlank() }.joinToString(" · ") else e.advice }
        val abnormal = CheckupPlan.abnormalCount(entries.map { it.snapshot() })
        val summary = "${report.checkupDateDay.orEmpty()} ${report.checkupInstitution.orEmpty()} · ${entries.count { it.kind == "item" }} 项 · $abnormal 项异常"
        db.memoryDao().upsert(report.copy(summary = summary, sourceText = lines.joinToString("\n") + RAW_MARKER + rawText(report)))
    }
    suspend fun normalizationPlan(owner: String?): CheckupReview {
        val before = dao.checkups().filter { it.profileUuid == owner }
        val snapshots = before.map { it.snapshot() }
        val catalog = CheckupNormalizer.catalog(snapshots)
        val config = app.settings.aiConfig()
        val ai = if (!config.apiKey.isNullOrBlank() && catalog.size >= 2) DeepSeekClient.matchCheckupNames(config, catalog) else emptyList()
        return CheckupReview(owner, before, CheckupNormalizer.plan(snapshots, CheckupNormalizer.merge(ai, CheckupNormalizer.localGroups(catalog))))
    }
    suspend fun applyNormalization(review: CheckupReview) = db.withTransaction {
        val latest = dao.checkups().filter { it.profileUuid == review.profileId }
        require(latest.associateBy { it.uuid } == review.before.associateBy { it.uuid }) { "报告已发生变化,请重新匹配检查项" }
        val reports = mutableSetOf<String>()
        for ((id, value) in review.plan.updates) {
            val old = latest.first { it.uuid == id }
            dao.saveCheckup(old.copy(name = value.name, value = value.value, unit = value.unit, referenceRange = value.reference, flag = value.flag,
                category = value.category, conclusion = value.conclusion, advice = value.advice)); reports += old.reportUuid
        }
        review.plan.removals.forEach { dao.deleteCheckup(it.id); reports += it.reportId }
        reports.forEach { refreshDerived(it) }
    }
    suspend fun deleteProfile(id: String) {
        val originals = db.withTransaction {
            val reports = db.memoryDao().all().filter { TAG in it.tagsList && it.checkupOwner() == id }
            reports.forEach { dao.deleteReportEntries(it.uuid); db.memoryDao().delete(it.uuid) }
            // 兼容旧版没有报告主记录的单独指标,不能把它们留下变成孤儿记录。
            dao.checkups().filter { it.profileUuid == id }.forEach { dao.deleteCheckup(it.uuid) }
            dao.deleteProfile(id); reports.mapNotNull { it.relativeFilePath }
        }
        originals.forEach { app.memoryFiles.remove(it) }
    }
}
