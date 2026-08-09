package com.lodo.app.data

import com.lodo.app.ai.AIConfig
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.MemoryCandidate
import com.lodo.app.core.MemorySearch
import com.lodo.app.core.TimeFormat
import kotlinx.coroutines.flow.Flow
import java.net.URI

/**
 * 记忆/收藏业务层,与 iOS MemoryPipeline + retrieveMemoryCandidates 同构的
 * 一个精简子集:纯文字/链接的收藏与整理 + 资产/人脉子功能,不含本地文件存储
 * (pdf/image/file、头像/附件)、分片/向量检索(MemoryChunk/embedding)——检索
 * 退化成 [MemorySearch] 的纯关键词版本,与 iOS "无 embedding 时退化成关键词
 * 搜索"是同一个合法降级路径。
 */
class MemoryRepository(
    private val db: LodoDatabase,
) {
    private val dao get() = db.memoryDao()
    private val taskDao get() = db.taskDao()

    fun observeAll(): Flow<List<MemoryEntity>> = dao.observeAll()

    suspend fun byUuid(uuid: String): MemoryEntity? = dao.byUuid(uuid)

    /** 普通标签筛选用的标签全集,排除资产/人脉两个保留标签(它们有自己专门的
     * 筛选开关,不跟普通标签混在一起改名/筛选——与 iOS MemoryListView.allTags/
     * MemoryTagManageView 一致)。 */
    suspend fun allTags(): List<String> = dao.all()
        .flatMap { it.tagsList }
        .filterNot { it == MemoryEntity.assetTagName || it == MemoryEntity.contactTagName }
        .distinct().sorted()

    /** 收藏一段文字:整段是裸链接时按 link 处理,否则按 text;立即插入
     * processing 条目,随后调用 AI 整理成标题/摘要/标签,失败退化成 fallback
     * 标题 + failed 状态(原文已保留,可重试)。 */
    suspend fun saveText(config: AIConfig, text: String): MemoryEntity {
        val trimmed = text.trim()
        val url = detectedUrl(trimmed)
        val item = MemoryEntity.create(
            kind = if (url != null) MemoryKind.LINK else MemoryKind.TEXT,
            sourceText = MemorySearch.truncate(trimmed),
            urlString = url,
        )
        dao.upsert(item)
        val organized = organize(config, item)
        dao.upsert(organized)
        return organized
    }

    /** 整理失败后重试:原文不变,重新调一次 AI。 */
    suspend fun retry(config: AIConfig, uuid: String) {
        val item = dao.byUuid(uuid) ?: return
        dao.upsert(item.copy(status = MemoryStatus.PROCESSING.raw))
        dao.upsert(organize(config, item))
    }

    private suspend fun organize(config: AIConfig, item: MemoryEntity): MemoryEntity {
        val existingTags = allTags()
        return try {
            val entry = DeepSeekClient.memorize(config, item.sourceText, item.kindEnum.raw, existingTags)
            item.copy(
                title = entry.title,
                summary = entry.summary,
                tags = joinCsv(entry.tags),
                status = MemoryStatus.READY.raw,
            )
        } catch (e: Exception) {
            item.copy(title = fallbackTitle(item), status = MemoryStatus.FAILED.raw)
        }
    }

    private fun fallbackTitle(item: MemoryEntity): String {
        val firstLine = item.sourceText.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
        return when {
            !firstLine.isNullOrEmpty() -> firstLine.take(20)
            item.urlString != null -> item.urlString
            else -> "收藏"
        }
    }

    /** 详情页保存编辑:标题/标签由用户直接改;资产/人脉标签由调用方保证仍在
     * tags 里(编辑普通记忆条目时不会有,资产/人脉详情页各自的保存函数负责)。 */
    suspend fun updateTitleAndTags(uuid: String, title: String, tags: List<String>) {
        val item = dao.byUuid(uuid) ?: return
        dao.upsert(item.copy(title = title, tags = joinCsv(tags)))
    }

    /** 删除记忆条目;是人脉的话联动清掉引用它的关系图谱边(与 iOS
     * MemoryPipeline.delete 一致)。 */
    suspend fun delete(uuid: String) {
        db.contactRelationshipDao().deleteForContact(uuid)
        dao.delete(uuid)
    }

    /** "记一笔资产":用户直接填结构化字段(标题/金额/币种/可选负债),不需要
     * 走 AI 整理——字段已经是结构化的,不像纯文字/链接那样需要先从原文提炼。
     * 直接 status=READY,即便没配置 AI key 也能用。tags 固定带上 assetTagName。 */
    suspend fun saveAsset(
        title: String, value: Double?, currency: String,
        liability: Double?, interestRate: Double?, extraTags: List<String> = emptyList(),
    ): MemoryEntity {
        val item = MemoryEntity.create(
            kind = MemoryKind.TEXT,
            title = title,
            status = MemoryStatus.READY,
            tags = (listOf(MemoryEntity.assetTagName) + extraTags).distinct(),
            assetValue = value,
            assetCurrency = currency,
            assetLiability = liability,
            assetInterestRate = interestRate,
        )
        dao.upsert(item)
        return item
    }

    suspend fun updateAsset(
        uuid: String, title: String, value: Double?, currency: String,
        liability: Double?, interestRate: Double?,
    ) {
        val item = dao.byUuid(uuid) ?: return
        dao.upsert(
            item.copy(
                title = title, assetValue = value, assetCurrency = currency,
                assetLiability = liability, assetInterestRate = interestRate,
            )
        )
    }

    /** "记一位人脉":同样是结构化字段直接落库,不走 AI 整理。姓名复用 title,
     * 备注复用 summary,与 iOS 一致。tags 固定带上 contactTagName。 */
    suspend fun saveContact(
        nickname: String, phone: String?, email: String?,
        birthdayMillis: Long?, preferences: String?, extraTags: List<String> = emptyList(),
    ): MemoryEntity {
        val item = MemoryEntity.create(
            kind = MemoryKind.TEXT,
            title = nickname,
            summary = preferences.orEmpty(),
            status = MemoryStatus.READY,
            tags = (listOf(MemoryEntity.contactTagName) + extraTags).distinct(),
            contactNickname = nickname,
            contactPhone = phone,
            contactEmail = email,
            contactBirthdayMillis = birthdayMillis,
            contactPreferences = preferences,
        )
        dao.upsert(item)
        return item
    }

    // ---- 人脉关系图谱 ----

    fun observeRelationships(): Flow<List<ContactRelationshipEntity>> = db.contactRelationshipDao().observeAll()

    suspend fun addRelationship(fromUuid: String, toUuid: String, label: String) {
        db.contactRelationshipDao().upsert(ContactRelationshipEntity.create(fromUuid, toUuid, label))
    }

    suspend fun deleteRelationship(uuid: String) = db.contactRelationshipDao().delete(uuid)

    suspend fun updateContact(
        uuid: String, nickname: String, phone: String?, email: String?,
        birthdayMillis: Long?, preferences: String?,
    ) {
        val item = dao.byUuid(uuid) ?: return
        dao.upsert(
            item.copy(
                title = nickname, summary = preferences.orEmpty(),
                contactNickname = nickname, contactPhone = phone, contactEmail = email,
                contactBirthdayMillis = birthdayMillis, contactPreferences = preferences,
            )
        )
    }

    /** ask_memory/search_memory 的关键词候选检索:记忆条目 + 已完成待办历史,
     * 与 iOS retrieveMemoryCandidates 同构(uuid 前缀 "task:" 避免和记忆条目
     * 撞 uuid 空间)。 */
    suspend fun retrieveCandidates(question: String): List<MemoryCandidate> {
        val memoryHits = MemorySearch.rank(
            question, dao.all(), MemorySearch.MAX_ASK_ITEMS,
            haystack = { "${it.title} ${it.summary} ${it.tagsList.joinToString(" ")} ${it.sourceText}" },
            createdAtMillis = { it.createdAtMillis },
        )
        val memoryCandidates = memoryHits.map {
            MemoryCandidate(
                uuid = it.uuid, title = it.title, summary = it.summary, tags = it.tagsList,
                excerpt = MemorySearch.truncate(it.sourceText, MemorySearch.MAX_EXCERPT_CHARS),
            )
        }
        val historyHits = MemorySearch.rankTaskHistory(
            question, taskDao.done(), MemorySearch.MAX_HISTORY_ITEMS,
            haystack = { it.title },
        )
        val historyCandidates = historyHits.map {
            MemoryCandidate(
                uuid = "task:${it.uuid}", title = it.title, summary = "", tags = emptyList(),
                excerpt = "已于 ${TimeFormat.format(it.doneAt ?: it.remindAt)} 完成",
            )
        }
        return memoryCandidates + historyCandidates
    }
}

/** 整段文本是不是一个裸链接(无换行/空格、http(s) 协议)——与 iOS
 * MemoryPipeline.detectedURL 一致。 */
internal fun detectedUrl(text: String): String? {
    if (text.isBlank() || text.contains('\n') || text.contains(' ')) return null
    val uri = try {
        URI(text)
    } catch (e: Exception) {
        return null
    }
    if (uri.scheme != "http" && uri.scheme != "https") return null
    if (uri.host.isNullOrBlank()) return null
    return text
}
