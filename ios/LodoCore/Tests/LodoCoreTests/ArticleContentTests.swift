import XCTest
@testable import LodoCore

final class ArticleContentTests: XCTestCase {
    private let base = URL(string: "https://example.com/news/1.html")!

    func testBlocksKeepOrderAndImages() {
        let html = """
        <html><body><nav><p>首页 导航 链接</p></nav>
        <article>
          <h1>页面标题</h1>
          <p>第一段正文,讲了一件事情的来龙去脉,足够长足够长足够长足够长足够长足够长。</p>
          <figure><img data-src="/img/a.jpg" src="data:image/gif;base64,xx"><figcaption>图注</figcaption></figure>
          <h2>小标题</h2>
          <p>第二段<b>加粗</b>正文,继续把事情讲清楚,足够长足够长足够长足够长足够长足够长足够长。</p>
          <blockquote><p>一句引用</p></blockquote>
          <ul><li>要点一</li><li>要点二</li></ul>
          <p><img src="//cdn.example.com/b.png" width="600"></p>
          <p>第三段正文,收个尾,足够长足够长足够长足够长足够长足够长足够长足够长足够长。</p>
          <img src="/icons/tiny.png" width="16" height="16">
        </article>
        <footer><p>版权所有</p></footer></body></html>
        """
        let content = ArticleExtractor.content(fromHTML: html, baseURL: base)
        XCTAssertNotNil(content)
        let blocks = content!.blocks
        XCTAssertEqual(blocks.first, .paragraph("第一段正文,讲了一件事情的来龙去脉,足够长足够长足够长足够长足够长足够长。"))
        XCTAssertTrue(blocks.contains(.image(URL(string: "https://example.com/img/a.jpg")!)))
        XCTAssertTrue(blocks.contains(.heading("小标题")))
        XCTAssertTrue(blocks.contains(.quote("一句引用")))
        XCTAssertTrue(blocks.contains(.listItem("要点一")))
        XCTAssertTrue(blocks.contains(.image(URL(string: "https://cdn.example.com/b.png")!)))
        // h1(页面标题)、导航、页脚、小图标都不进正文。
        XCTAssertFalse(blocks.contains(.heading("页面标题")))
        XCTAssertFalse(content!.text.contains("版权所有"))
        XCTAssertFalse(content!.text.contains("首页"))
        XCTAssertEqual(content!.imageCount, 2)
        // 图片在第一段之后、小标题之前(保持原文顺序)。
        let imageIndex = blocks.firstIndex(of: .image(URL(string: "https://example.com/img/a.jpg")!))!
        let headingIndex = blocks.firstIndex(of: .heading("小标题"))!
        XCTAssertLessThan(imageIndex, headingIndex)
    }

    func testFallsBackToPlainTextWithImages() {
        // 没有块级结构、正文在 JSON-LD 里:按纯文本分段,抽到的图片放开头。
        let body = String(repeating: "这是正文内容。", count: 30)
        let html = """
        <html><head><script type="application/ld+json">{"articleBody": "\(body)"}</script></head>
        <body><img src="https://example.com/cover.jpg"></body></html>
        """
        let content = ArticleExtractor.content(fromHTML: html, baseURL: base)!
        XCTAssertEqual(content.blocks.first, .image(URL(string: "https://example.com/cover.jpg")!))
        XCTAssertEqual(content.text, body)
    }

    func testReaderMarkdown() {
        let markdown = """
        Title: 标题
        URL Source: https://example.com
        Markdown Content:
        # 小标题
        第一段有一个[链接](https://example.com/x)和**加粗**。
        ![图](https://example.com/c.jpg)
        > 引用一句
        - 列表项
        ---
        """
        let content = ArticleExtractor.content(fromReaderMarkdown: markdown, baseURL: base)!
        XCTAssertEqual(content.blocks, [
            .heading("小标题"),
            .paragraph("第一段有一个链接和加粗。"),
            .image(URL(string: "https://example.com/c.jpg")!),
            .quote("引用一句"),
            .listItem("列表项"),
        ])
    }

    func testImageURLUpgradesHTTPAndSkipsIcons() {
        XCTAssertEqual(ArticleExtractor.imageURL("<img src=\"http://a.com/x.jpg\">", base: base),
                       URL(string: "https://a.com/x.jpg"))
        XCTAssertNil(ArticleExtractor.imageURL("<img src=\"/logo.svg\">", base: base))
        XCTAssertNil(ArticleExtractor.imageURL("<img src=\"/a.jpg\" width=\"1\" height=\"1\">", base: base))
    }

    func testDuplicateImagesKeptOnce() {
        let url = URL(string: "https://example.com/a.jpg")!
        let trimmed = ArticleExtractor.trimmed(ArticleContent(blocks: [
            .image(url), .paragraph("一"), .image(url), .paragraph("一"), .paragraph("一"),
        ]))
        XCTAssertEqual(trimmed.blocks, [.image(url), .paragraph("一")])
    }

    func testDropsNavigationLikeListRuns() {
        let years = (2010...2014).map { ArticleBlock.listItem("\($0)") }
        let blocks: [ArticleBlock] = [.paragraph("正文")] + years
            + [.listItem("两项短的"), .listItem("保留"), .paragraph("尾"),
               .listItem("正文里一条很长很长的要点,写得比较详细"),
               .listItem("另一条也写得相当详细的要点内容"), .listItem("第三条同样很详细的要点说明文字")]
        // 「两项短的」「保留」紧跟在 5 个年份后面,同属一串短列表,一起去掉;
        // 长的要点列表保留。
        XCTAssertEqual(ArticleExtractor.droppingNavigationLists(blocks), [
            .paragraph("正文"),
            .paragraph("尾"),
            .listItem("正文里一条很长很长的要点,写得比较详细"),
            .listItem("另一条也写得相当详细的要点内容"),
            .listItem("第三条同样很详细的要点说明文字"),
        ])
        // 只有两个短项的不算导航。
        let short: [ArticleBlock] = [.listItem("甲"), .listItem("乙"), .paragraph("文")]
        XCTAssertEqual(ArticleExtractor.droppingNavigationLists(short), short)
    }

    func testCutsAtRelatedHeading() {
        let blocks: [ArticleBlock] = [.heading("More about this"), .paragraph("正文"),
                                      .heading("小标题"), .paragraph("正文二"),
                                      .heading("More recent articles"), .listItem("另一篇")]
        // 第一段正文之前的不截(那时还没开始正文),「More recent articles」之后全部截掉。
        XCTAssertEqual(ArticleExtractor.cuttingTail(blocks), Array(blocks.prefix(4)))
        XCTAssertEqual(ArticleExtractor.cuttingTail([.paragraph("文"), .heading("相关阅读"), .paragraph("别的")]),
                       [.paragraph("文")])
        XCTAssertEqual(ArticleExtractor.cuttingTail([.paragraph("文"), .heading("更新日志"), .paragraph("还是正文")]).count, 3)
    }

    func testDigestReferencesResolveToArticles() throws {
        let entries = (1...3).map { NewsEntry(feedTitle: "源", title: "文章\($0)", publishedAt: Date()) }
        let digest = try DeepSeekClient.parseNewsDigest([
            "overview": "概览",
            "items": [["title": "一件事", "detail": "", "refs": [2, "3", 9, 2]]],
        ]).resolvingReferences(entries)
        XCTAssertEqual(digest.items[0].refs, [2, 3, 9, 2])
        XCTAssertEqual(digest.items[0].articleIDs, [entries[1].uuid, entries[2].uuid])
    }

    func testNumberedPromptLines() {
        let entries = [NewsEntry(feedTitle: "源", title: "甲", publishedAt: Date()),
                       NewsEntry(feedTitle: "源", title: "乙", publishedAt: Date())]
        let lines = NewsPlan.promptLines(entries, numbered: true)
        XCTAssertTrue(lines.hasPrefix("[1] [源] 甲"))
        XCTAssertTrue(lines.contains("\n[2] [源] 乙"))
        XCTAssertTrue(NewsPlan.promptLines(entries).hasPrefix("- [源] 甲"))
    }
}
