import XCTest
@testable import LodoCore

final class ArticleExtractorTests: XCTestCase {
    private let longSentence = String(repeating: "这是正文里的一句完整的话,讲了具体的事情。", count: 8)

    func testPrefersJSONLDArticleBody() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[{"@type":"NewsArticle","articleBody":"\(longSentence)"}]}
        </script></head><body><nav><p>首页导航链接很多很多很多</p></nav><p>短</p></body></html>
        """
        XCTAssertEqual(ArticleExtractor.mainText(fromHTML: html), longSentence)
    }

    func testFallsBackToParagraphsAndDropsNavigation() {
        let html = """
        <html><body><header><p>站点头部的一大段导航文字不应该出现</p></header>
        <div class="content"><p>\(longSentence)</p><p>第二段也是正文,长度足够。</p><p>分享</p></div>
        <footer><p>版权所有 某某公司 保留一切权利</p></footer></body></html>
        """
        let text = ArticleExtractor.mainText(fromHTML: html) ?? ""
        XCTAssertTrue(text.contains(longSentence))
        XCTAssertTrue(text.contains("第二段也是正文"))
        XCTAssertFalse(text.contains("导航"))
        XCTAssertFalse(text.contains("版权所有"))
        XCTAssertFalse(text.contains("分享"))
    }

    func testMetaDescriptionWhenNoBody() {
        let html = #"<html><head><meta property="og:description" content="只有一句描述"></head><body></body></html>"#
        XCTAssertEqual(ArticleExtractor.mainText(fromHTML: html), "只有一句描述")
        XCTAssertNil(ArticleExtractor.mainText(fromHTML: "<html><body><p>短</p></body></html>"))
    }

    func testCleanReaderMarkdown() {
        let markdown = """
        Title: 标题
        URL Source: https://example.com
        Markdown Content:
        # 大标题
        ![图](https://x/y.png)
        正文里有个[链接](https://z)。
        """
        let text = ArticleExtractor.cleanReaderMarkdown(markdown)
        XCTAssertEqual(text, "大标题\n正文里有个链接。")
    }

    func testDecodeGBK() {
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "<meta charset=\"gbk\">中文".data(using: String.Encoding(rawValue: gb))!
        XCTAssertEqual(ArticleExtractor.decode(data, contentType: nil), "<meta charset=\"gbk\">中文")
    }
}
