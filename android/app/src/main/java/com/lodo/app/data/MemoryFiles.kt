package com.lodo.app.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.lodo.app.core.MemoryFilePolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** 原件仅存应用私有目录;向外打开临时授予只读权限,不请求全盘存储权限。 */
class MemoryFiles(private val context: Context) {
    data class Stored(val name: String, val relativePath: String, val kind: MemoryKind)
    fun resolve(relative: String?): File? {
        if (relative == null || !MemoryFilePolicy.safePath(relative)) return null
        val root = context.filesDir.canonicalFile
        val file = File(root, relative).canonicalFile
        return file.takeIf { it.path.startsWith(root.path + File.separator) }
    }

    suspend fun copy(uri: Uri): Stored = withContext(Dispatchers.IO) {
        val name = AttachmentExtractor.displayName(context, uri).substringAfterLast('/').substringAfterLast('\\').take(255).ifBlank { "附件" }
        val type = context.contentResolver.getType(uri).orEmpty()
        val ext = MemoryFilePolicy.extension(name)
        val kind = when {
            type == "application/pdf" || ext == "pdf" -> MemoryKind.PDF
            type.startsWith("image/") || ext in setOf("jpg", "jpeg", "png", "webp", "gif", "heic", "heif") -> MemoryKind.IMAGE
            else -> MemoryKind.FILE
        }
        val relative = "Memory/${UUID.randomUUID()}.$ext"
        val target = resolve(relative)!!
        target.parentFile!!.mkdirs()
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> MemoryFilePolicy.copyLimited(input, output, MemoryFilePolicy.MAX_FILE_BYTES) }
            } ?: error("无法读取文件")
            Stored(name, relative, kind)
        } catch (e: Exception) { target.delete(); throw e }
    }

    fun remove(relative: String?) { resolve(relative)?.delete() }

    fun open(item: MemoryEntity, share: Boolean = false) {
        val file = resolve(item.relativeFilePath)?.takeIf { it.isFile } ?: error("原文件不在本机")
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
        val intent = if (share) Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri)
        else Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, item.originalFileName ?: item.title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
