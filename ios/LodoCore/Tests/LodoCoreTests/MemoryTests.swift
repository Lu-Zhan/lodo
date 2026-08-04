import XCTest
@testable import LodoCore

/// AI 收藏/记忆的纯逻辑测试:整理/问答结果解析、截断、类型映射、粗排。
final class MemoryTests: XCTestCase {

    // MARK: - parseMemorizedEntry

    func testParseMemorizedEntry() throws {
        let entry = try DeepSeekClient.parseMemorizedEntry([
            "title": " SwiftUI 手势指南 ",
            "summary": "介绍拖拽与捏合手势的组合用法。",
            "tags": ["SwiftUI", "手势"],
        ])
        XCTAssertEqual(entry.title, "SwiftUI 手势指南")
        XCTAssertEqual(entry.summary, "介绍拖拽与捏合手势的组合用法。")
        XCTAssertEqual(entry.tags, ["SwiftUI", "手势"])
    }

    func testParseMemorizedEntryMissingTitleThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseMemorizedEntry(["summary": "x"]))
        XCTAssertThrowsError(try DeepSeekClient.parseMemorizedEntry(["title": "  "]))
    }

    func testParseMemorizedEntryTolerantFields() throws {
        // summary/tags 缺失或类型混杂时不报错,尽量取值
        let entry = try DeepSeekClient.parseMemorizedEntry([
            "title": "只有标题", "tags": ["ok", 42] as [Any],
        ])
        XCTAssertEqual(entry.summary, "")
        XCTAssertEqual(entry.tags, ["ok"])
    }

    // MARK: - parseMemoryAnswer

    func testParseMemoryAnswer() throws {
        let (answer, related) = try DeepSeekClient.parseMemoryAnswer(
            ["answer": "找到两条相关收藏。", "related_uuids": ["a", "b", "ghost"]],
            validUUIDs: ["a", "b", "c"])
        XCTAssertEqual(answer, "找到两条相关收藏。")
        // 不在列表内的 uuid 被过滤
        XCTAssertEqual(related, ["a", "b"])
    }

    func testParseMemoryAnswerMissingAnswerThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseMemoryAnswer(
            ["related_uuids": []], validUUIDs: []))
    }

    // MARK: - truncate

    func testTruncate() {
        XCTAssertEqual(MemorySearch.truncate("  hello  ", limit: 10), "hello")
        XCTAssertEqual(MemorySearch.truncate("", limit: 10), "")
        XCTAssertEqual(MemorySearch.truncate("abcdef", limit: 3), "abc…")
        // Character 边界:emoji 不劈半
        let flags = String(repeating: "🇨🇳", count: 5)
        XCTAssertEqual(MemorySearch.truncate(flags, limit: 3), "🇨🇳🇨🇳🇨🇳…")
    }

    // MARK: - kind(forExtension:)

    func testKindForExtension() {
        XCTAssertEqual(MemorySearch.kind(forExtension: "PDF"), .pdf)
        XCTAssertEqual(MemorySearch.kind(forExtension: "jpeg"), .image)
        XCTAssertEqual(MemorySearch.kind(forExtension: "md"), .text)
        XCTAssertEqual(MemorySearch.kind(forExtension: "pptx"), .file)
        XCTAssertEqual(MemorySearch.kind(forExtension: ""), .file)
    }

    // MARK: - rank

    func testRankPrefersKeywordOverlap() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            (index: 0, text: "周末去爬山的装备清单", createdAt: base),
            (index: 1, text: "SwiftUI 布局笔记", createdAt: base.addingTimeInterval(60)),
            (index: 2, text: "爬山路线图与注意事项", createdAt: base.addingTimeInterval(120)),
        ]
        let ranked = MemorySearch.rank(question: "爬山要带什么", items: items, limit: 2)
        XCTAssertEqual(ranked.count, 2)
        // 两条含"爬山"的排前面,不含的被挤掉
        XCTAssertEqual(Set(ranked), [0, 2])
    }

    func testRankFallsBackToRecency() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let items = [
            (index: 0, text: "旧条目", createdAt: base),
            (index: 1, text: "新条目", createdAt: base.addingTimeInterval(60)),
        ]
        // 无任何命中时按创建时间倒序兜底
        let ranked = MemorySearch.rank(question: "quantum", items: items, limit: 2)
        XCTAssertEqual(ranked, [1, 0])
    }

    func testRankRespectsLimit() {
        let base = Date()
        let items = (0..<30).map { (index: $0, text: "记忆 \($0)", createdAt: base) }
        XCTAssertEqual(MemorySearch.rank(question: "记忆", items: items).count,
                       MemorySearch.maxAskItems)
    }

    // MARK: - matchTaskHistory

    func testMatchTaskHistoryPrefersScoreOrder() {
        let items = [
            (index: 0, title: "交材料给行政"),
            (index: 1, title: "开周会"),
            (index: 2, title: "交材料复印件"),
        ]
        let matched = MemorySearch.matchTaskHistory(question: "上次交材料是什么时候", items: items)
        XCTAssertEqual(Set(matched), [0, 2])
        XCTAssertFalse(matched.contains(1))
    }

    func testMatchTaskHistoryReturnsEmptyWithoutRecencyPadding() {
        let items = [
            (index: 0, title: "旧条目"),
            (index: 1, title: "新条目"),
        ]
        // 与 rank(:) 不同,零命中时不拿近期条目填充,直接返回空。
        XCTAssertEqual(MemorySearch.matchTaskHistory(question: "quantum", items: items), [])
    }

    func testMatchTaskHistoryRespectsLimit() {
        let items = (0..<30).map { (index: $0, title: "交材料 \($0)") }
        XCTAssertEqual(MemorySearch.matchTaskHistory(question: "交材料", items: items, limit: 5).count, 5)
    }

    // MARK: - tokens

    func testTokensMixedLanguage() {
        let terms = Set(MemorySearch.tokens(of: "SwiftUI 手势"))
        XCTAssertTrue(terms.contains("swiftui"))
        XCTAssertTrue(terms.contains("手势"))
    }

    // MARK: - MemoryItem.matches(本地过滤)

    @MainActor
    func testMemoryItemMatches() {
        let item = MemoryItem(kind: .link, title: "山径路线", summary: "适合周末的短途路线",
                              tags: ["户外"], sourceText: "从东门出发全程约三小时")
        XCTAssertTrue(item.matches(""))
        XCTAssertTrue(item.matches("路线"))
        XCTAssertTrue(item.matches("户外"))
        XCTAssertTrue(item.matches("东门"))
        XCTAssertFalse(item.matches("烹饪"))
    }
}
