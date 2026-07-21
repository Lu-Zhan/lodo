import XCTest
@testable import LodoCore

/// DeepSeekClient.parseThreadTitle 离线单测(对话标题解析)。
final class ThreadTitleTests: XCTestCase {
    func testParsesAndTrimsTitle() throws {
        let title = try DeepSeekClient.parseThreadTitle(["title": "  安排周会  "])
        XCTAssertEqual(title, "安排周会")
    }

    func testMissingTitleThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseThreadTitle([:]))
    }

    func testBlankTitleThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseThreadTitle(["title": "   "]))
    }
}
