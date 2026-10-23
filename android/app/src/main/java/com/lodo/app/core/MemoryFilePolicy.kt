package com.lodo.app.core

import java.io.InputStream
import java.io.OutputStream

/** 文件/zip 共用的边界,拒绝路径穿越、压缩炸弹和无限读入内存。 */
object MemoryFilePolicy {
    const val MAX_FILE_BYTES = 50L * 1024 * 1024
    const val MAX_BACKUP_BYTES = 512L * 1024 * 1024
    const val MAX_JSON_BYTES = 16L * 1024 * 1024
    const val MAX_ZIP_ENTRIES = 10000
    private val path = Regex("Memory/[a-zA-Z0-9_-]{1,80}\\.[a-zA-Z0-9]{1,12}")
    fun safePath(value: String): Boolean = path.matches(value)
    fun extension(name: String): String = name.substringAfterLast('.', "bin").lowercase()
        .takeIf { Regex("[a-z0-9]{1,12}").matches(it) } ?: "bin"
    fun copyLimited(input: InputStream, output: OutputStream, maxBytes: Long): Long {
        val buffer = ByteArray(32 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            require(total <= maxBytes) { "文件过大,超过允许的大小" }
            output.write(buffer, 0, read)
        }
        return total
    }
}
