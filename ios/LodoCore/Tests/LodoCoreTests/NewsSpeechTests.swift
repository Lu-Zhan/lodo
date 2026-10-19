import XCTest
@testable import LodoCore

final class NewsSpeechTests: XCTestCase {
    func testArticleSkipsImagesAndRepeatedTitle() {
        let blocks: [ArticleBlock] = [.heading("新机发布"), .paragraph("今天发布了新机。"),
                                      .image(URL(string: "https://example.com/a.jpg")!), .listItem("续航更长")]
        let text = NewsSpeech.article(title: "新机发布", blocks: blocks, fallback: "摘要")
        XCTAssertEqual(text, "新机发布\n今天发布了新机。\n续航更长")
    }

    func testArticleFallsBackToFeedSummary() {
        XCTAssertEqual(NewsSpeech.article(title: "T", blocks: [], fallback: " 摘要 "), "T\n摘要")
        XCTAssertEqual(NewsSpeech.article(title: "T", blocks: [], fallback: ""), "T")
    }

    func testBriefPrefersAISummary() {
        let summary = NewsArticleSummary(summary: "一句话", points: ["要点一", " "])
        XCTAssertEqual(NewsSpeech.brief(title: "T", aiSummary: summary, feedSummary: "feed"), "T\n一句话\n要点一")
        XCTAssertEqual(NewsSpeech.brief(title: "T", aiSummary: nil, feedSummary: "feed"), "T\nfeed")
    }

    func testDigestNumbersItems() {
        let digest = NewsDigest(overview: "概览", items: [
            NewsDigest.Item(title: "苹果发布会", detail: "下周举行。", source: ""),
            NewsDigest.Item(title: "降价了。", detail: "又降了。", source: ""),
        ])
        XCTAssertEqual(NewsSpeech.digest(digest), "概览\n1. 苹果发布会\u{3002}下周举行。\n2. 降价了。又降了。")
    }

    func testChunksSplitLongTextAtSentences() {
        let sentence = String(repeating: "字", count: 9) + "\u{3002}"   // 10 字一句
        let text = String(repeating: sentence, count: 5) + "\n短的一行"
        let chunks = NewsSpeech.chunks(text, limit: 25)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 10, 4])
        XCTAssertEqual(chunks.joined(), text.replacingOccurrences(of: "\n", with: ""))
    }

    func testChunksHardSplitWithoutPunctuation() {
        let text = String(repeating: "a", count: 23)
        XCTAssertEqual(NewsSpeech.chunks(text, limit: 10).map(\.count), [10, 10, 3])
    }
}
