import XCTest
@testable import LodoCore

final class NewsReadingSettingsTests: XCTestCase {
    func testSummaryLanguagePromptNames() {
        XCTAssertEqual(NewsSummaryLanguage.followApp.promptName(appLanguage: .zhHans), "中文")
        XCTAssertEqual(NewsSummaryLanguage.followApp.promptName(appLanguage: .en), "英文")
        XCTAssertEqual(NewsSummaryLanguage.japanese.promptName(appLanguage: .en), "日文")
        XCTAssertEqual(NewsSummaryLanguage.original.promptName(appLanguage: .zhHans), "文章原文所用的语言")
    }

    func testStoredValuesFallBackToDefaults() {
        XCTAssertEqual(NewsSummaryLanguage.stored(nil), .followApp)
        XCTAssertEqual(NewsSummaryLanguage.stored("xx"), .followApp)
        XCTAssertEqual(NewsSummaryLanguage.stored("ko"), .korean)
        XCTAssertEqual(NewsFontSize.stored(nil), .standard)
        XCTAssertEqual(NewsFontSize.stored(99), .standard)
        XCTAssertEqual(NewsFontSize.stored(4), .largest)
        XCTAssertEqual(NewsMargin.stored(nil), .standard)
        XCTAssertEqual(NewsMargin.stored(2), .wide)
        XCTAssertLessThan(NewsMargin.narrow.points, NewsMargin.standard.points)
        XCTAssertLessThan(NewsMargin.standard.points, NewsMargin.wide.points)
    }
}
