import XCTest
@testable import LodoCore

/// 长对话上下文压缩的离线单测:摘要存储(读写/水位线/重置)、prompt 拼接块、
/// 以及 payload 解析。每个用例前后清空文件,不留下本机状态
/// (与 AgentPreferencesTests 一样直接跑真实路径,用例自己负责清理)。
final class ConversationSummaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentConversationSummary.reset()
    }

    override func tearDown() {
        AgentConversationSummary.reset()
        super.tearDown()
    }

    // MARK: - 存储

    func testEmptyByDefault() {
        XCTAssertNil(AgentConversationSummary.content)
        XCTAssertEqual(AgentConversationSummary.coveredUntil, .distantPast)
        XCTAssertEqual(AgentConversationSummary.coveredCount, 0)
    }

    func testSaveAndReadBackWithWatermark() {
        let until = Date(timeIntervalSince1970: 1_783_000_000)
        AgentConversationSummary.save("用户住在杭州,对花生过敏。", coveredUntil: until,
                                      coveredCount: 24)
        XCTAssertEqual(AgentConversationSummary.content, "用户住在杭州,对花生过敏。")
        XCTAssertEqual(AgentConversationSummary.coveredUntil, until)
        XCTAssertEqual(AgentConversationSummary.coveredCount, 24)
    }

    /// 存空内容等同重置——否则会留下一份只有水位线、没有正文的文件,
    /// 之后那批消息既不在摘要里也永远不会被重压。
    func testSaveBlankResets() {
        AgentConversationSummary.save("有内容", coveredUntil: Date(), coveredCount: 3)
        AgentConversationSummary.save("   \n  ", coveredUntil: Date(), coveredCount: 9)
        XCTAssertNil(AgentConversationSummary.content)
        XCTAssertEqual(AgentConversationSummary.coveredUntil, .distantPast)
    }

    func testResetClearsEverything() {
        AgentConversationSummary.save("有内容", coveredUntil: Date(), coveredCount: 3)
        AgentConversationSummary.reset()
        XCTAssertNil(AgentConversationSummary.content)
        XCTAssertEqual(AgentConversationSummary.coveredCount, 0)
    }

    /// 窗口大小要小于触发压缩的批量,否则每压一次都会把窗口里的消息也卷进去。
    func testWindowIsSmallerThanCompressBatch() {
        XCTAssertLessThan(AgentConversationSummary.recentWindow,
                          AgentConversationSummary.compressBatch)
    }

    // MARK: - prompt 拼接

    func testSummaryBlockEmptyForNil() {
        XCTAssertEqual(DeepSeekClient.summaryBlock(nil), "")
    }

    func testSummaryBlockEmptyForBlank() {
        XCTAssertEqual(DeepSeekClient.summaryBlock("   \n "), "")
    }

    func testSummaryBlockCarriesText() {
        let block = DeepSeekClient.summaryBlock("用户住在杭州。")
        XCTAssertTrue(block.contains("用户住在杭州。"))
        XCTAssertTrue(block.contains("更早对话的摘要"))
    }

    // MARK: - 解析

    func testParseTrimsSummary() throws {
        let summary = try DeepSeekClient.parseConversationSummary(["summary": "  聊了旅行  "])
        XCTAssertEqual(summary, "聊了旅行")
    }

    func testParseThrowsWhenMissing() {
        XCTAssertThrowsError(try DeepSeekClient.parseConversationSummary([:]))
    }

    func testParseThrowsWhenBlank() {
        XCTAssertThrowsError(try DeepSeekClient.parseConversationSummary(["summary": "   "]))
    }
}
