package com.lodo.app.data

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.lodo.app.ai.AIConfig
import com.lodo.app.ai.DeepSeekClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 端上 OCR:ML Kit 文字识别(中/日/韩三个识别器各跑一遍,取认出字最多的那份)。
 * 只在本机识别,图片不上传,只把文字发给 AI(同 iOS ContentExtractor.recognizeMenuText)。
 */
object Ocr {
    suspend fun recognize(context: Context, uri: Uri): String = withContext(Dispatchers.Default) {
        val image = runCatching { InputImage.fromFilePath(context, uri) }.getOrNull()
            ?: runCatching {
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                    ?.let { InputImage.fromBitmap(it, 0) }
            }.getOrNull()
            ?: return@withContext ""
        val recognizers = listOf(
            TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build()),
            TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build()),
            TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build()),
        )
        val results = recognizers.mapNotNull { r ->
            runCatching { Tasks.await(r.process(image)).text }.getOrNull().also { r.close() }
        }
        results.maxByOrNull { text -> text.count { !it.isWhitespace() } }.orEmpty()
    }
}

/**
 * 菜单:整张菜单是打了「菜单」标签的记忆条目(清单 + OCR 原文进 sourceText,能被记忆搜索命中),
 * 菜品是独立轻量表 MenuDishEntity(同 iOS,数量级原因不做成记忆条目)。
 * 这条路径不给确认页:整理完直接落库,中途失败什么都不留。
 */
class MenuRepository(private val db: LodoDatabase) {
    private val dao get() = db.menuDao()

    fun observeDishes(menuUuid: String) = dao.observeDishes(menuUuid)
    fun observeAllDishes() = dao.observeAllDishes()

    suspend fun create(config: AIConfig, text: String): MemoryEntity {
        val target = DeepSeekClient.languageName()
        val menu = DeepSeekClient.parseMenu(config, text, target)
        if (menu.dishes.isEmpty()) throw IllegalStateException(com.lodo.app.ui.L("没有读出任何菜品", "No dishes recognized"))
        val title = menu.restaurant.ifBlank { com.lodo.app.ui.L("菜单", "Menu") + " · " + java.time.LocalDate.now() }
        val listing = menu.dishes.joinToString("\n") { d ->
            "${d.originalName}" + (if (d.translatedName.isNotBlank() && d.translatedName != d.originalName) "(${d.translatedName})" else "") +
                (d.price?.let { " ${menu.currency ?: ""}$it" } ?: "") + (if (d.intro.isNotBlank()) ":${d.intro}" else "")
        }
        val entity = MemoryEntity.create(
            kind = MemoryKind.TEXT, title = title,
            summary = com.lodo.app.ui.L("${menu.dishes.size} 道菜", "${menu.dishes.size} dishes") +
                (if (menu.sourceLanguage.isNotBlank()) " · ${menu.sourceLanguage}" else ""),
            sourceText = (listing + "\n\n" + text).take(8000),
            tags = listOf(MemoryEntity.menuTagName), status = MemoryStatus.READY,
        ).copy(menuSourceLanguage = menu.sourceLanguage, menuTargetLanguage = target, menuCurrency = menu.currency)
        db.memoryDao().upsert(entity)
        menu.dishes.forEachIndexed { i, d ->
            dao.upsert(MenuDishEntity(
                menuUuid = entity.uuid, originalName = d.originalName, translatedName = d.translatedName,
                intro = d.intro, category = d.category, price = d.price, sortIndex = i,
            ))
        }
        return entity
    }

    suspend fun setSelected(uuid: String, selected: Boolean) = dao.setSelected(uuid, selected)
    suspend fun clearSelection(menuUuid: String) = dao.clearSelection(menuUuid)
}
