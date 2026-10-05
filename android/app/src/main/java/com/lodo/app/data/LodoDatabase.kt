package com.lodo.app.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** v1→v2:给 status+nextRemindAtMillis / status+doneAtMillis 加复合索引,加速
 * 待办/已完成分流查询(TaskDao.observePending/observeDone),不改表结构、不丢数据。 */
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS index_tasks_status_nextRemindAtMillis " +
                "ON tasks(status, nextRemindAtMillis)"
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS index_tasks_status_doneAtMillis " +
                "ON tasks(status, doneAtMillis)"
        )
    }
}

/** v2→v3:新增记忆表(对应 iOS MemoryItem 的核心字段,不含资产/人脉子功能字段)。 */
val MIGRATION_2_3 = object : Migration(2, 3) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS memories (
                uuid TEXT NOT NULL PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                tags TEXT NOT NULL,
                sourceText TEXT NOT NULL,
                urlString TEXT,
                status TEXT NOT NULL,
                createdAtMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_memories_status ON memories(status)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_memories_createdAtMillis ON memories(createdAtMillis)")
    }
}

/** v3→v4:给记忆表加资产/人脉子功能字段(与 iOS 一致——不是独立表,是普通记忆
 * 条目上打了保留标签后额外用到的一组列),都可空、不影响已有数据。 */
val MIGRATION_3_4 = object : Migration(3, 4) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE memories ADD COLUMN assetValue REAL")
        db.execSQL("ALTER TABLE memories ADD COLUMN assetCurrency TEXT")
        db.execSQL("ALTER TABLE memories ADD COLUMN assetLiability REAL")
        db.execSQL("ALTER TABLE memories ADD COLUMN assetInterestRate REAL")
        db.execSQL("ALTER TABLE memories ADD COLUMN contactNickname TEXT")
        db.execSQL("ALTER TABLE memories ADD COLUMN contactPhone TEXT")
        db.execSQL("ALTER TABLE memories ADD COLUMN contactEmail TEXT")
        db.execSQL("ALTER TABLE memories ADD COLUMN contactBirthdayMillis INTEGER")
        db.execSQL("ALTER TABLE memories ADD COLUMN contactPreferences TEXT")
    }
}

/** v4→v5:新增定时任务表(AI 例行任务)+ 执行记录表。 */
val MIGRATION_4_5 = object : Migration(4, 5) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS routines (
                uuid TEXT NOT NULL PRIMARY KEY,
                prompt TEXT NOT NULL,
                remindAtMillis INTEGER NOT NULL,
                repeatType TEXT NOT NULL,
                repeatDays TEXT NOT NULL,
                repeatTimes TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                nextRunAtMillis INTEGER NOT NULL,
                lastRunAtMillis INTEGER,
                lastResultText TEXT,
                createdAtMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS index_routines_enabled_nextRunAtMillis " +
                "ON routines(enabled, nextRunAtMillis)"
        )
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS routine_runs (
                uuid TEXT NOT NULL PRIMARY KEY,
                routineUuid TEXT NOT NULL,
                resultText TEXT NOT NULL,
                ranAtMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
    }
}

/** v5→v6:新增人脉关系表(关系图谱)。 */
val MIGRATION_5_6 = object : Migration(5, 6) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS contact_relationships (
                uuid TEXT NOT NULL PRIMARY KEY,
                fromUuid TEXT NOT NULL,
                toUuid TEXT NOT NULL,
                label TEXT NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_contact_relationships_fromUuid ON contact_relationships(fromUuid)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_contact_relationships_toUuid ON contact_relationships(toUuid)")
    }
}

/** v6→v7:新增"忽略"动作的连续计数(区别于被动的通知重排,间隔逐次翻倍),
 * 默认 0 不影响已有数据。 */
val MIGRATION_6_7 = object : Migration(6, 7) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE tasks ADD COLUMN ignoreStreak INTEGER NOT NULL DEFAULT 0")
    }
}

/** v7→v8:对齐 iOS 的一批新功能——任务置顶/项目、倒数日、收入支出信用卡、旅行
 * (旅行本身/行李清单 + 记忆条目上的行程字段)、菜单菜品、新闻订阅与文章、AI 对话
 * 消息。全是新表或可空/有默认值的新列,不动已有数据。 */
val MIGRATION_7_8 = object : Migration(7, 8) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE tasks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
        db.execSQL("ALTER TABLE tasks ADD COLUMN pinnedAtMillis INTEGER")
        db.execSQL("ALTER TABLE tasks ADD COLUMN project TEXT NOT NULL DEFAULT ''")
        listOf(
            "assetUpdatedAtMillis INTEGER", "travelTripUuid TEXT", "travelKind TEXT",
            "travelStartMillis INTEGER", "travelEndMillis INTEGER", "travelPlaceName TEXT",
            "travelOriginName TEXT", "travelCode TEXT", "travelPrice REAL", "travelCurrency TEXT",
            "travelLatitude REAL", "travelLongitude REAL", "travelFlightData TEXT", "travelNote TEXT",
            "menuSourceLanguage TEXT", "menuTargetLanguage TEXT", "menuCurrency TEXT",
        ).forEach { db.execSQL("ALTER TABLE memories ADD COLUMN $it") }
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS countdowns (
                uuid TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, startMillis INTEGER NOT NULL,
                endMillis INTEGER, allDay INTEGER NOT NULL, notes TEXT NOT NULL,
                startReminders TEXT NOT NULL, endReminders TEXT NOT NULL,
                showInWidget INTEGER NOT NULL, archived INTEGER NOT NULL, createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS finance_entries (
                uuid TEXT NOT NULL PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, amount REAL,
                currency TEXT NOT NULL, cadence TEXT NOT NULL, dayOfMonth INTEGER, statementDay INTEGER,
                institution TEXT NOT NULL, endDateMillis INTEGER, notes TEXT NOT NULL,
                remindEnabled INTEGER NOT NULL, reminderCycle TEXT NOT NULL, reminderTaskUuid TEXT,
                sortIndex INTEGER NOT NULL, updatedAtMillis INTEGER NOT NULL, createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS trips (
                uuid TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, emoji TEXT NOT NULL,
                startMillis INTEGER NOT NULL, endMillis INTEGER NOT NULL, city TEXT NOT NULL,
                country TEXT NOT NULL, notes TEXT NOT NULL, travelersJson TEXT NOT NULL,
                createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS packing_items (
                uuid TEXT NOT NULL PRIMARY KEY, tripUuid TEXT NOT NULL, title TEXT NOT NULL,
                category TEXT NOT NULL, packed INTEGER NOT NULL, sortIndex INTEGER NOT NULL,
                createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_packing_items_tripUuid ON packing_items(tripUuid)")
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS menu_dishes (
                uuid TEXT NOT NULL PRIMARY KEY, menuUuid TEXT NOT NULL, originalName TEXT NOT NULL,
                translatedName TEXT NOT NULL, intro TEXT NOT NULL, category TEXT NOT NULL, price REAL,
                selected INTEGER NOT NULL, sortIndex INTEGER NOT NULL)"""
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_menu_dishes_menuUuid ON menu_dishes(menuUuid)")
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS news_feeds (
                uuid TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, url TEXT NOT NULL,
                siteUrl TEXT NOT NULL, kind TEXT NOT NULL, enabled INTEGER NOT NULL,
                lastFetchedMillis INTEGER, createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS news_articles (
                uuid TEXT NOT NULL PRIMARY KEY, feedUuid TEXT NOT NULL, dedupeKey TEXT NOT NULL,
                title TEXT NOT NULL, summary TEXT NOT NULL, link TEXT NOT NULL, author TEXT NOT NULL,
                publishedMillis INTEGER NOT NULL, fetchedMillis INTEGER NOT NULL, read INTEGER NOT NULL,
                starred INTEGER NOT NULL, aiSummaryJson TEXT)"""
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_news_articles_feedUuid ON news_articles(feedUuid)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_news_articles_publishedMillis ON news_articles(publishedMillis)")
        db.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_news_articles_feedUuid_dedupeKey " +
                "ON news_articles(feedUuid, dedupeKey)"
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS agent_messages (
                uuid TEXT NOT NULL PRIMARY KEY, role TEXT NOT NULL, kind TEXT NOT NULL,
                content TEXT NOT NULL, payloadJson TEXT, createdAtMillis INTEGER NOT NULL)"""
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS index_agent_messages_createdAtMillis ON agent_messages(createdAtMillis)")
    }
}

/** v8→v9:旅行多目的地(第二个起的目的地,JSON)。 */
val MIGRATION_8_9 = object : Migration(8, 9) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE trips ADD COLUMN extraDestinations TEXT NOT NULL DEFAULT ''")
    }
}

@Database(
    entities = [
        TaskEntity::class, MemoryEntity::class, RoutineEntity::class, RoutineRunEntity::class,
        ContactRelationshipEntity::class, CountdownEntity::class, FinanceEntity::class,
        TripEntity::class, PackingEntity::class, MenuDishEntity::class, NewsFeedEntity::class,
        NewsArticleEntity::class, AgentMessageEntity::class,
    ],
    version = 9, exportSchema = false,
)
abstract class LodoDatabase : RoomDatabase() {
    abstract fun taskDao(): TaskDao
    abstract fun memoryDao(): MemoryDao
    abstract fun routineDao(): RoutineDao
    abstract fun contactRelationshipDao(): ContactRelationshipDao
    abstract fun countdownDao(): CountdownDao
    abstract fun financeDao(): FinanceDao
    abstract fun tripDao(): TripDao
    abstract fun menuDao(): MenuDao
    abstract fun newsDao(): NewsDao
    abstract fun agentMessageDao(): AgentMessageDao

    companion object {
        @Volatile
        private var instance: LodoDatabase? = null

        fun get(context: Context): LodoDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext, LodoDatabase::class.java, "lodo.db"
                ).addMigrations(
                    MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6,
                    MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9,
                ).build().also { instance = it }
            }
    }
}
