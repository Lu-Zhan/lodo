import XCTest
@testable import LodoCore

final class MemoryChunkerTests: XCTestCase {
    func testEmptyTextReturnsNoChunks() {
        XCTAssertEqual(MemoryChunker.split(""), [])
        XCTAssertEqual(MemoryChunker.split("   \n  "), [])
    }

    func testShortTextIsSingleChunk() {
        let text = "记住 wifi 密码是 8888"
        XCTAssertEqual(MemoryChunker.split(text), [text])
    }

    func testLongTextSplitsWithOverlap() {
        // 每个字符不同,方便断言重叠区间的具体内容
        let text = String((0..<2000).map { Character(UnicodeScalar(65 + $0 % 26)!) })
        let chunks = MemoryChunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        // 拼起来(去重叠)应能还原原文长度量级:每片不超过 targetChars
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, MemoryChunker.targetChars)
        }
        // 相邻两片有重叠:前一片的结尾应该是后一片开头的前缀
        let overlap = String(chunks[0].suffix(MemoryChunker.overlapChars))
        XCTAssertTrue(chunks[1].hasPrefix(overlap))
        // 最后一片能覆盖到原文末尾
        XCTAssertTrue(text.hasSuffix(chunks.last!))
    }

    func testNoInfiniteLoopOnEdgeSizes() {
        let text = String(repeating: "字", count: MemoryChunker.targetChars + 1)
        let chunks = MemoryChunker.split(text)
        XCTAssertFalse(chunks.isEmpty)
    }
}
