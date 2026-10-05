package com.lodo.app.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.provider.OpenableColumns
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * AI 对话附件 → 文字(同 iOS 的附件处理:照片在端上 OCR 成文字发出去,图片本身不上传)。
 * 照片走 ML Kit;PDF 把前几页渲染成图再 OCR;文本类文件直接读。都截到 8000 字(同联网抓取的量级)。
 */
object AttachmentExtractor {
    const val MAX_CHARS = 8000

    fun displayName(context: Context, uri: Uri): String = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment ?: "附件"

    suspend fun image(context: Context, uri: Uri): String = Ocr.recognize(context, uri).take(MAX_CHARS)

    suspend fun file(context: Context, uri: Uri): String = withContext(Dispatchers.IO) {
        val type = context.contentResolver.getType(uri).orEmpty()
        val name = displayName(context, uri).lowercase()
        when {
            type.startsWith("image/") -> image(context, uri)
            type == "application/pdf" || name.endsWith(".pdf") -> pdf(context, uri)
            else -> runCatching {
                context.contentResolver.openInputStream(uri)?.use { it.readBytes().decodeToString() }.orEmpty()
            }.getOrDefault("").take(MAX_CHARS)
        }
    }

    private suspend fun pdf(context: Context, uri: Uri): String = withContext(Dispatchers.IO) {
        val out = StringBuilder()
        runCatching {
            context.contentResolver.openFileDescriptor(uri, "r")?.use { fd ->
                PdfRenderer(fd).use { renderer ->
                    val recognizer = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                    for (i in 0 until minOf(renderer.pageCount, 5)) {
                        renderer.openPage(i).use { page ->
                            val scale = 2
                            val bmp = Bitmap.createBitmap(page.width * scale, page.height * scale, Bitmap.Config.ARGB_8888)
                            bmp.eraseColor(Color.WHITE)
                            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            runCatching { Tasks.await(recognizer.process(InputImage.fromBitmap(bmp, 0))).text }.getOrNull()
                                ?.let { out.append(it).append("\n") }
                            bmp.recycle()
                        }
                        if (out.length >= MAX_CHARS) break
                    }
                    recognizer.close()
                }
            }
        }
        out.toString().take(MAX_CHARS)
    }
}
