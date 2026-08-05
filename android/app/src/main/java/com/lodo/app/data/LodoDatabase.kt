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

@Database(entities = [TaskEntity::class], version = 2, exportSchema = false)
abstract class LodoDatabase : RoomDatabase() {
    abstract fun taskDao(): TaskDao

    companion object {
        @Volatile
        private var instance: LodoDatabase? = null

        fun get(context: Context): LodoDatabase =
            instance ?: synchronized(this) {
                instance ?: Room.databaseBuilder(
                    context.applicationContext, LodoDatabase::class.java, "lodo.db"
                ).addMigrations(MIGRATION_1_2).build().also { instance = it }
            }
    }
}
