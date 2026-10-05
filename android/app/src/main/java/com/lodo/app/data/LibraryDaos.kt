package com.lodo.app.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface CountdownDao {
    @Query("SELECT * FROM countdowns ORDER BY startMillis")
    fun observeAll(): Flow<List<CountdownEntity>>

    @Query("SELECT * FROM countdowns ORDER BY startMillis")
    suspend fun all(): List<CountdownEntity>

    @Query("SELECT * FROM countdowns WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): CountdownEntity?

    @Upsert
    suspend fun upsert(item: CountdownEntity)

    @Query("DELETE FROM countdowns WHERE uuid = :uuid")
    suspend fun delete(uuid: String)
}

@Dao
interface FinanceDao {
    @Query("SELECT * FROM finance_entries ORDER BY kind, sortIndex, createdAtMillis")
    fun observeAll(): Flow<List<FinanceEntity>>

    @Query("SELECT * FROM finance_entries ORDER BY kind, sortIndex, createdAtMillis")
    suspend fun all(): List<FinanceEntity>

    @Query("SELECT * FROM finance_entries WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): FinanceEntity?

    @Upsert
    suspend fun upsert(item: FinanceEntity)

    @Query("DELETE FROM finance_entries WHERE uuid = :uuid")
    suspend fun delete(uuid: String)
}

@Dao
interface TripDao {
    @Query("SELECT * FROM trips ORDER BY startMillis DESC")
    fun observeAll(): Flow<List<TripEntity>>

    @Query("SELECT * FROM trips ORDER BY startMillis DESC")
    suspend fun all(): List<TripEntity>

    @Query("SELECT * FROM trips WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): TripEntity?

    @Query("SELECT * FROM trips WHERE uuid = :uuid LIMIT 1")
    fun observe(uuid: String): Flow<TripEntity?>

    @Upsert
    suspend fun upsert(item: TripEntity)

    @Query("DELETE FROM trips WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    @Query("SELECT * FROM packing_items WHERE tripUuid = :tripUuid ORDER BY sortIndex, createdAtMillis")
    fun observePacking(tripUuid: String): Flow<List<PackingEntity>>

    @Query("SELECT * FROM packing_items WHERE tripUuid = :tripUuid ORDER BY sortIndex, createdAtMillis")
    suspend fun packing(tripUuid: String): List<PackingEntity>

    @Query("SELECT * FROM packing_items")
    suspend fun allPacking(): List<PackingEntity>

    @Upsert
    suspend fun upsertPacking(item: PackingEntity)

    @Query("DELETE FROM packing_items WHERE uuid = :uuid")
    suspend fun deletePacking(uuid: String)

    @Query("DELETE FROM packing_items WHERE tripUuid = :tripUuid")
    suspend fun deletePackingForTrip(tripUuid: String)
}

@Dao
interface MenuDao {
    @Query("SELECT * FROM menu_dishes WHERE menuUuid = :menuUuid ORDER BY sortIndex")
    fun observeDishes(menuUuid: String): Flow<List<MenuDishEntity>>

    @Query("SELECT * FROM menu_dishes")
    suspend fun allDishes(): List<MenuDishEntity>

    @Query("SELECT * FROM menu_dishes")
    fun observeAllDishes(): Flow<List<MenuDishEntity>>

    @Upsert
    suspend fun upsert(item: MenuDishEntity)

    @Query("UPDATE menu_dishes SET selected = :selected WHERE uuid = :uuid")
    suspend fun setSelected(uuid: String, selected: Boolean)

    @Query("UPDATE menu_dishes SET selected = 0 WHERE menuUuid = :menuUuid")
    suspend fun clearSelection(menuUuid: String)

    @Query("DELETE FROM menu_dishes WHERE menuUuid = :menuUuid")
    suspend fun deleteForMenu(menuUuid: String)
}

@Dao
interface NewsDao {
    @Query("SELECT * FROM news_feeds ORDER BY createdAtMillis")
    fun observeFeeds(): Flow<List<NewsFeedEntity>>

    @Query("SELECT * FROM news_feeds ORDER BY createdAtMillis")
    suspend fun feeds(): List<NewsFeedEntity>

    @Query("SELECT * FROM news_feeds WHERE uuid = :uuid LIMIT 1")
    suspend fun feed(uuid: String): NewsFeedEntity?

    @Upsert
    suspend fun upsertFeed(item: NewsFeedEntity)

    @Query("DELETE FROM news_feeds WHERE uuid = :uuid")
    suspend fun deleteFeed(uuid: String)

    @Query("SELECT * FROM news_articles ORDER BY publishedMillis DESC LIMIT 2000")
    fun observeArticles(): Flow<List<NewsArticleEntity>>

    @Query("SELECT * FROM news_articles ORDER BY publishedMillis DESC")
    suspend fun articles(): List<NewsArticleEntity>

    @Query("SELECT * FROM news_articles WHERE feedUuid = :feedUuid ORDER BY publishedMillis DESC")
    suspend fun articles(feedUuid: String): List<NewsArticleEntity>

    @Query("SELECT * FROM news_articles WHERE uuid = :uuid LIMIT 1")
    suspend fun article(uuid: String): NewsArticleEntity?

    @Query("SELECT * FROM news_articles WHERE uuid = :uuid LIMIT 1")
    fun observeArticle(uuid: String): Flow<NewsArticleEntity?>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertArticleIfNew(item: NewsArticleEntity): Long

    @Upsert
    suspend fun upsertArticle(item: NewsArticleEntity)

    @Query("DELETE FROM news_articles WHERE uuid = :uuid")
    suspend fun deleteArticle(uuid: String)

    @Query("DELETE FROM news_articles WHERE feedUuid = :feedUuid AND starred = 0")
    suspend fun deleteUnstarredForFeed(feedUuid: String)
}

@Dao
interface AgentMessageDao {
    /** 倒序取最近 limit 条,调用方再翻回正序(对话永不结束,不能全表灌进来)。 */
    @Query("SELECT * FROM agent_messages ORDER BY createdAtMillis DESC LIMIT :limit")
    fun observeRecent(limit: Int): Flow<List<AgentMessageEntity>>

    @Query("SELECT * FROM agent_messages ORDER BY createdAtMillis DESC LIMIT :limit")
    suspend fun recent(limit: Int): List<AgentMessageEntity>

    @Query("SELECT COUNT(*) FROM agent_messages")
    suspend fun count(): Int

    @Query("SELECT * FROM agent_messages WHERE uuid = :uuid LIMIT 1")
    suspend fun byUuid(uuid: String): AgentMessageEntity?

    @Upsert
    suspend fun upsert(item: AgentMessageEntity)

    @Query("DELETE FROM agent_messages WHERE uuid = :uuid")
    suspend fun delete(uuid: String)

    @Query("DELETE FROM agent_messages WHERE createdAtMillis >= :fromMillis")
    suspend fun deleteFrom(fromMillis: Long)

    @Query("DELETE FROM agent_messages")
    suspend fun clear()
}
