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

/** OCR 在本地执行。聊天附件限 8000 字;完整报告最多 100 页/120000 字,超限明确报错。 */
object AttachmentExtractor {
    const val MAX_CHARS = 8000
    fun displayName(context: Context, uri: Uri): String = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment ?: "附件"

    suspend fun image(context: Context, uri: Uri): String = Ocr.recognize(context, uri).take(MAX_CHARS)
    suspend fun file(context: Context, uri: Uri): String = extract(context, uri, MAX_CHARS, 5, false)
    suspend fun report(context: Context, uri: Uri): String = extract(context, uri, 120000, 100, true)

    private suspend fun extract(context: Context, uri: Uri, limit: Int, pageLimit: Int, strict: Boolean): String = withContext(Dispatchers.IO) {
        val type = context.contentResolver.getType(uri).orEmpty()
        val name = displayName(context, uri).lowercase()
        val text = when {
            type.startsWith("image/") || name.substringAfterLast('.') in setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif") -> Ocr.recognize(context, uri)
            type == "application/pdf" || name.endsWith(".pdf") -> pdf(context, uri, limit, pageLimit, strict)
            else -> context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { reader ->
                val chars = CharArray(limit + 1)
                var total = 0
                while (total < chars.size) {
                    val n = reader.read(chars, total, chars.size - total)
                    if (n < 0) break
                    total += n
                }
                String(chars, 0, total)
            } ?: error("无法打开文件")
        }
        require(!strict || text.length <= limit) { "报告超过 $limit 字,请拆分后导入" }
        text.take(limit)
    }

    private suspend fun pdf(context: Context, uri: Uri, limit: Int, pageLimit: Int, strict: Boolean): String = withContext(Dispatchers.IO) {
        val out = StringBuilder()
        val fd = context.contentResolver.openFileDescriptor(uri, "r") ?: error("无法打开 PDF")
        fd.use {
            PdfRenderer(it).use { renderer ->
                require(!strict || renderer.pageCount <= pageLimit) { "报告超过 $pageLimit 页,请拆分后导入" }
                val recognizer = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
                try {
                    for (i in 0 until minOf(renderer.pageCount, pageLimit)) {
                        renderer.openPage(i).use { page ->
                            val scale = minOf(2f, 2400f / maxOf(page.width, page.height).coerceAtLeast(1))
                            val bmp = Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                            try {
                                bmp.eraseColor(Color.WHITE)
                                page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                out.append(Tasks.await(recognizer.process(InputImage.fromBitmap(bmp, 0))).text).append('\n')
                            } finally { bmp.recycle() }
                        }
                        if (out.length > limit) break
                    }
                } finally { recognizer.close() }
            }
        }
        out.toString()
    }
}
