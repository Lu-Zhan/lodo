package com.lodo.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.UUID

/*
 * 这一轮跟 iOS 对齐时新加的几张表(v8)。分层和 iOS 一致:
 * - 倒数日、收入/支出/信用卡、旅行本身、行李清单、菜品、新闻订阅与文章、AI 对话消息
 *   都是独立的轻量表;
 * - 旅行的行程项、整张菜单仍然是打了保留标签的记忆条目(字段挂在 MemoryEntity 上),
 *   理由同 iOS:订单原文能被记忆搜索和"问 AI"命中。
 * 存储字符串(kind/cadence/status 这些)与 iOS 的 rawValue 逐字一致,别改。
 */

private fun newUuid() = UUID.randomUUID().toString()

/** 倒数日,对应 iOS CountdownEvent。提醒是"开始/结束前多少分钟",CSV 存。 */
@Entity(tableName = "countdowns")
data class CountdownEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val title: String,
    val startMillis: Long,
    val endMillis: Long? = null,
    val allDay: Boolean = true,
    val notes: String = "",
    val startReminders: String = "",
    val endReminders: String = "",
    val showInWidget: Boolean = false,
    val archived: Boolean = false,
    val createdAtMillis: Long = System.currentTimeMillis(),
) {
    val startReminderList: List<Int> get() = splitIntCsv(startReminders)
    val endReminderList: List<Int> get() = splitIntCsv(endReminders)
}

/** 收入 / 固定支出 / 信用卡,对应 iOS FinanceEntry。kind:income/expense/creditCard;
 * cadence:monthly/quarterly/yearly/irregular。 */
@Entity(tableName = "finance_entries")
data class FinanceEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val kind: String,
    val title: String,
    val amount: Double? = null,
    val currency: String = "CNY",
    val cadence: String = "monthly",
    /** 收入/支出:每月几号;信用卡:还款日。 */
    val dayOfMonth: Int? = null,
    /** 信用卡账单日。 */
    val statementDay: Int? = null,
    val institution: String = "",
    val endDateMillis: Long? = null,
    val notes: String = "",
    val remindEnabled: Boolean = true,
    /** 已经为哪一期(还款日 yyyy-MM-dd)建过提醒任务,防重复。 */
    val reminderCycle: String = "",
    val reminderTaskUuid: String? = null,
    val sortIndex: Int = 0,
    val updatedAtMillis: Long = System.currentTimeMillis(),
    val createdAtMillis: Long = System.currentTimeMillis(),
)

/** 一次旅行(名字/起止日/目的地/备注),对应 iOS TravelTrip。行程项是记忆条目。 */
@Entity(tableName = "trips")
data class TripEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val title: String,
    val emoji: String = "",
    val startMillis: Long,
    val endMillis: Long,
    val city: String = "",
    val country: String = "",
    val notes: String = "",
    /** 同行人 JSON 数组:[{"id","name","note","contactUuid"}]。 */
    val travelersJson: String = "",
    val createdAtMillis: Long = System.currentTimeMillis(),
    /** 第二个起的目的地(JSON),第一个仍是 city/country 两列(同 iOS extraDestinations)。 */
    val extraDestinations: String = "",
) {
    val displayEmoji: String get() = emoji.ifBlank { "✈️" }
    /** 全部目的地,读一律走这里(第一个 = city/country)。 */
    val destinations: List<com.lodo.app.core.TripDestination>
        get() = com.lodo.app.core.TripDestination.all(city, country, extraDestinations)
    /** 列表/卡片上那段目的地文字。 */
    val destinationLabel: String get() = com.lodo.app.core.TripDestination.summary(destinations)
}

/** 旅行用品清单的一件,对应 iOS PackingItem。 */
@Entity(tableName = "packing_items", indices = [Index("tripUuid")])
data class PackingEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val tripUuid: String,
    val title: String,
    val category: String = "其他",
    val packed: Boolean = false,
    val sortIndex: Int = 0,
    val createdAtMillis: Long = System.currentTimeMillis(),
)

/** 菜单里的一道菜,对应 iOS MenuDish;整张菜单是打了「菜单」标签的记忆条目。 */
@Entity(tableName = "menu_dishes", indices = [Index("menuUuid")])
data class MenuDishEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val menuUuid: String,
    val originalName: String,
    val translatedName: String = "",
    val intro: String = "",
    val category: String = "",
    val price: Double? = null,
    val selected: Boolean = false,
    val sortIndex: Int = 0,
)

/** 新闻/博客订阅,kind:news/blog(对应 iOS NewsFeedKind 存储值)。 */
@Entity(tableName = "news_feeds")
data class NewsFeedEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val title: String,
    val url: String,
    val siteUrl: String = "",
    val kind: String = "news",
    val enabled: Boolean = true,
    val lastFetchedMillis: Long? = null,
    val createdAtMillis: Long = System.currentTimeMillis(),
)

/** 一篇文章:只存标题/纯文本摘要/链接,不存正文(打开时现抓),同 iOS。 */
@Entity(
    tableName = "news_articles",
    indices = [Index("feedUuid"), Index("publishedMillis"), Index(value = ["feedUuid", "dedupeKey"], unique = true)],
)
data class NewsArticleEntity(
    @PrimaryKey val uuid: String = newUuid(),
    val feedUuid: String,
    val dedupeKey: String,
    val title: String,
    val summary: String = "",
    val link: String = "",
    val author: String = "",
    val publishedMillis: Long,
    val fetchedMillis: Long = System.currentTimeMillis(),
    val read: Boolean = false,
    val starred: Boolean = false,
    /** AI 总结 JSON:{"summary": "...", "points": [...]}。 */
    val aiSummaryJson: String? = null,
)

/**
 * AI 助手对话里的一条消息,对应 iOS AgentMessage。AI 助手是一条永不结束的单一对话,
 * 全表按 createdAt 排序就是对话本身。kind 决定气泡怎么画,payloadJson 是那种卡片的快照
 * (确认清单/结果/提问/行程规划……),content 是喂回给模型的纯文字版。
 */
@Entity(tableName = "agent_messages", indices = [Index("createdAtMillis")])
data class AgentMessageEntity(
    @PrimaryKey val uuid: String = newUuid(),
    /** user / assistant */
    val role: String,
    val kind: String,
    val content: String,
    val payloadJson: String? = null,
    val createdAtMillis: Long = System.currentTimeMillis(),
)
