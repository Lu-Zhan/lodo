package com.lodo.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.time.LocalDateTime
import java.util.UUID

/** 记忆条目的内容类型;与 iOS MemoryKind 对齐,这一轮只做 text/link 两种
 * (pdf/image/file 需要文件选择与本地存储基础设施,留待后续跟进)。 */
enum class MemoryKind(val raw: String) {
    TEXT("text"),
    LINK("link");

    companion object {
        fun from(raw: String): MemoryKind = entries.firstOrNull { it.raw == raw } ?: TEXT
    }
}

/** 整理状态:AI 整理中 / 已整理 / 整理失败(原文已保留,可重试)。 */
enum class MemoryStatus(val raw: String) {
    PROCESSING("processing"),
    READY("ready"),
    FAILED("failed");

    companion object {
        fun from(raw: String): MemoryStatus = entries.firstOrNull { it.raw == raw } ?: READY
    }
}

/**
 * "AI 收藏/记忆"条目,与 iOS MemoryItem 对齐。这一轮 port 纯文字/链接的核心字段 +
 * 资产/人脉子功能字段(与 iOS 一样,资产/人脉不是独立模型,是打了保留标签
 * [assetTagName]/[contactTagName] 的普通记忆条目,靠这组额外字段承载数据)。
 * 不含 pdf/image/file 的本地文件存储、头像/附件、与 RAG 分片/向量检索
 * (MemoryChunk/embedding)——检索退化成纯关键词匹配,与 iOS "无 embedding 时
 * 退化成关键词搜索"是同一个合法的降级路径,不是残缺实现。
 */
@Entity(
    tableName = "memories",
    indices = [Index(value = ["status"]), Index(value = ["createdAtMillis"])],
)
data class MemoryEntity(
    @PrimaryKey val uuid: String,
    val kind: String,
    val title: String,
    val summary: String,
    /** CSV 存取,与 TaskEntity.repeatTimes 同一个约定(joinCsv/splitCsv)。 */
    val tags: String,
    val sourceText: String,
    val urlString: String?,
    val status: String,
    val createdAtMillis: Long,
    /** 资产条目(tags 含 [assetTagName])的金额;非资产条目为 null。 */
    val assetValue: Double? = null,
    /** 资产金额对应的 ISO 4217 币种代码(如 "CNY"/"USD");null 按人民币对待
     * (见 [assetCurrencyOrDefault])。 */
    val assetCurrency: String? = null,
    /** 这项资产对应的负债本金(房贷/车贷本金等),与 assetValue 同币种,可以
     * 独立于 assetValue 存在。 */
    val assetLiability: Double? = null,
    /** 负债的年化利率,存百分比数值本身(如 4.5 表示 4.5%)。 */
    val assetInterestRate: Double? = null,
    /** 人脉条目(tags 含 [contactTagName])的昵称;姓名复用 title,备注复用
     * summary,与 iOS 一致。 */
    val contactNickname: String? = null,
    val contactPhone: String? = null,
    val contactEmail: String? = null,
    val contactBirthdayMillis: Long? = null,
    /** 喜好,自由文本。 */
    val contactPreferences: String? = null,
) {
    val kindEnum: MemoryKind get() = MemoryKind.from(kind)
    val statusEnum: MemoryStatus get() = MemoryStatus.from(status)
    val tagsList: List<String> get() = splitCsv(tags)
    val createdAt: LocalDateTime get() = createdAtMillis.toLocalDateTime()
    val contactBirthday: LocalDateTime? get() = contactBirthdayMillis?.toLocalDateTime()
    val isAsset: Boolean get() = tagsList.contains(assetTagName)
    val isContact: Boolean get() = tagsList.contains(contactTagName)
    val assetCurrencyOrDefault: String get() = assetCurrency ?: "CNY"

    /** 本地关键词过滤,对应 iOS MemoryItem.matches(_:)——标题/摘要/标签/原文,
     * 空查询恒真。 */
    fun matches(query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return true
        return title.contains(q, ignoreCase = true) ||
            summary.contains(q, ignoreCase = true) ||
            tagsList.any { it.contains(q, ignoreCase = true) } ||
            sourceText.contains(q, ignoreCase = true)
    }

    companion object {
        /** 与 iOS MemoryItem.assetTagName/contactTagName 一致的保留标签字面量。 */
        const val assetTagName = "资产"
        const val contactTagName = "人脉"

        fun create(
            kind: MemoryKind,
            sourceText: String = "",
            urlString: String? = null,
            title: String = "",
            summary: String = "",
            tags: List<String> = emptyList(),
            status: MemoryStatus = MemoryStatus.PROCESSING,
            assetValue: Double? = null,
            assetCurrency: String? = null,
            assetLiability: Double? = null,
            assetInterestRate: Double? = null,
            contactNickname: String? = null,
            contactPhone: String? = null,
            contactEmail: String? = null,
            contactBirthdayMillis: Long? = null,
            contactPreferences: String? = null,
        ) = MemoryEntity(
            uuid = UUID.randomUUID().toString(),
            kind = kind.raw,
            title = title,
            summary = summary,
            tags = joinCsv(tags),
            sourceText = sourceText,
            urlString = urlString,
            status = status.raw,
            createdAtMillis = LocalDateTime.now().toEpochMillis(),
            assetValue = assetValue,
            assetCurrency = assetCurrency,
            assetLiability = assetLiability,
            assetInterestRate = assetInterestRate,
            contactNickname = contactNickname,
            contactPhone = contactPhone,
            contactEmail = contactEmail,
            contactBirthdayMillis = contactBirthdayMillis,
            contactPreferences = contactPreferences,
        )
    }
}
