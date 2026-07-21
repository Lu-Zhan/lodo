import XCTest
@testable import LodoCore

/// DeepSeekClient.historyBlock 的纯字符串拼接单测(多轮对话 prompt 片段)。
final class HistoryBlockTests: XCTestCase {
    func testEmptyHistoryReturnsEmptyString() {
        XCTAssertEqual(DeepSeekClient.historyBlock([]), "")
    }

    func testMapsRoleLabelsAndPreservesOrder() {
        let block = DeepSeekClient.historyBlock([
            (role: "user", content: "明天3点开会"),
            (role: "assistant", content: "已创建:开会(明天 15:00)"),
            (role: "user", content: "改到下午4点"),
        ])
        XCTAssertTrue(block.contains("用户:明天3点开会"))
        XCTAssertTrue(block.contains("助手:已创建:开会(明天 15:00)"))
        XCTAssertTrue(block.contains("用户:改到下午4点"))
        let userIndex = block.range(of: "用户:明天3点开会")!.lowerBound
        let assistantIndex = block.range(of: "助手:已创建")!.lowerBound
        XCTAssertLessThan(userIndex, assistantIndex)
    }
}
