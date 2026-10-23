package com.lodo.app.core

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class MemoryFilePolicyTest {
    @Test fun generatedRelativePathAllowed() { assertTrue(MemoryFilePolicy.safePath("Memory/abc-123_X.pdf")) }
    @Test fun traversalRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/../secret.txt")); assertFalse(MemoryFilePolicy.safePath("../Memory/a.pdf")) }
    @Test fun absolutePathRejected() { assertFalse(MemoryFilePolicy.safePath("/Memory/a.pdf")) }
    @Test fun backslashRejected() { assertFalse(MemoryFilePolicy.safePath("Memory\\a.pdf")) }
    @Test fun nestedDirectoryRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/sub/a.pdf")) }
    @Test fun encodedTraversalRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/%2e%2e.pdf")) }
    @Test fun nulRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/a\u0000.pdf")) }
    @Test fun otherDirectoryRejected() { assertFalse(MemoryFilePolicy.safePath("files/a.pdf")) }
    @Test fun missingExtensionRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/abc")) }
    @Test fun longNameRejected() { assertFalse(MemoryFilePolicy.safePath("Memory/" + "a".repeat(81) + ".pdf")) }
    @Test fun extensionsNormalizedAndBounded() { assertEquals("pdf", MemoryFilePolicy.extension("报告.PDF")); assertEquals("bin", MemoryFilePolicy.extension("报告")); assertEquals("bin", MemoryFilePolicy.extension("x.abcdefghijklmn")) }
    @Test fun limitedCopyAtBoundarySucceeds() {
        val output = ByteArrayOutputStream(); assertEquals(3L, MemoryFilePolicy.copyLimited(ByteArrayInputStream(byteArrayOf(1, 2, 3)), output, 3))
        assertArrayEquals(byteArrayOf(1, 2, 3), output.toByteArray())
    }
    @Test(expected = IllegalArgumentException::class) fun limitedCopyRejectsOneByteOver() { MemoryFilePolicy.copyLimited(ByteArrayInputStream(byteArrayOf(1, 2, 3)), ByteArrayOutputStream(), 2) }
    @Test fun emptyFileAllowed() { assertEquals(0L, MemoryFilePolicy.copyLimited(ByteArrayInputStream(byteArrayOf()), ByteArrayOutputStream(), 0)) }
}
