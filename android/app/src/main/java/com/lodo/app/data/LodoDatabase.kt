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

@Database(
    entities = [
        TaskEntity::class, MemoryEntity::class, RoutineEntity::class, RoutineRunEntity::class,
        ContactRelationshipEntity::class,
    ],
    version = 6, exportSchema = false,
)
abstract class LodoDatabase : RoomDatabase() {
    abstract fun taskDao(): TaskDao
    abstract fun memoryDao(): MemoryDao
    abstract fun routineDao(): RoutineDao
    abstract fun contactRelationshipDao(): ContactRelationshipDao

    companion object {
        @Volatile
        private var instance: LodoDatabase? = null

        fun get(context: Context): LodoDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext, LodoDatabase::class.java, "lodo.db"
                ).addMigrations(
                    MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6,
                ).build().also { instance = it }
            }
    }
}
