import XCTest
@testable import LodoCore

final class NewsFeedTests: XCTestCase {
    // MARK: - 解析

    func testParsesRSS2() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
             xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel>
          <title>少数派</title>
          <link>https://sspai.com</link>
          <image><title>不该当成站名</title></image>
          <item>
            <title>一篇 &amp; 文章</title>
            <link>https://sspai.com/post/1</link>
            <guid isPermaLink="false">post-1</guid>
            <pubDate>Wed, 08 Jul 2026 09:00:00 +0800</pubDate>
            <dc:creator>作者甲</dc:creator>
            <description><![CDATA[<p>第一段<br/>第二段</p><script>evil()</script>]]></description>
          </item>
          <item>
            <title>没有 guid 的</title>
            <link>https://sspai.com/post/2</link>
            <content:encoded><![CDATA[<div>正文 &#20013;&#x6587;</div>]]></content:encoded>
          </item>
        </channel>
        </rss>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(feed.title, "少数派")
        XCTAssertEqual(feed.siteURL, "https://sspai.com")
        XCTAssertEqual(feed.items.count, 2)
        let first = feed.items[0]
        XCTAssertEqual(first.title, "一篇 & 文章")
        XCTAssertEqual(first.dedupeKey, "post-1")
        XCTAssertEqual(first.author, "作者甲")
        XCTAssertEqual(first.summary, "第一段\n第二段")
        XCTAssertEqual(first.published, Date(timeIntervalSince1970: 1_783_472_400))
        let second = feed.items[1]
        XCTAssertEqual(second.dedupeKey, "https://sspai.com/post/2")
        XCTAssertEqual(second.summary, "正文 中文")
        XCTAssertNil(second.published)
    }

    func testParsesAtom() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>阮一峰的网络日志</title>
          <link rel="self" href="https://www.ruanyifeng.com/blog/atom.xml"/>
          <link href="https://www.ruanyifeng.com/blog/"/>
          <entry>
            <title>科技爱好者周刊</title>
            <link rel="alternate" type="text/html" href="https://www.ruanyifeng.com/blog/2026/07/weekly.html"/>
            <link rel="replies" href="https://example.com/comments"/>
            <id>tag:ruanyifeng.com,2026:/blog//1.2</id>
            <published>2026-07-08T01:00:00Z</published>
            <updated>2026-07-09T01:00:00.123Z</updated>
            <author><name>阮一峰</name></author>
            <content type="html">&lt;p&gt;这里记录每周值得分享的科技内容&lt;/p&gt;</content>
          </entry>
        </feed>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(feed.title, "阮一峰的网络日志")
        XCTAssertEqual(feed.siteURL, "https://www.ruanyifeng.com/blog/")
        let entry = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(entry.link, "https://www.ruanyifeng.com/blog/2026/07/weekly.html")
        XCTAssertEqual(entry.author, "阮一峰")
        XCTAssertEqual(entry.summary, "这里记录每周值得分享的科技内容")
        XCTAssertEqual(entry.published, Date(timeIntervalSince1970: 1_783_472_400))
    }

    func testRejectsHTMLAsNotAFeed() {
        XCTAssertThrowsError(try FeedParser.parse(Data("<html><body>hi</body></html>".utf8))) {
            XCTAssertEqual($0 as? FeedParseError, .notAFeed)
        }
    }

    func testDateFormats() {
        let expected = Date(timeIntervalSince1970: 1_783_501_200) // 2026-07-08 09:00 UTC
        XCTAssertEqual(FeedDate.parse("Wed, 08 Jul 2026 09:00:00 GMT"), expected)
        XCTAssertEqual(FeedDate.parse("Wed, 8 Jul 2026 09:00:00 +0000"), expected)
        XCTAssertEqual(FeedDate.parse("2026-07-08T17:00:00+08:00"), expected)
        XCTAssertNil(FeedDate.parse("昨天"))
    }

    func testExcerptTruncates() {
        let long = String(repeating: "字", count: NewsText.excerptLimit + 10)
        XCTAssertEqual(NewsText.excerpt(long).count, NewsText.excerptLimit + 1)
        XCTAssertTrue(NewsText.excerpt(long).hasSuffix("…"))
    }

    // MARK: - 博客订阅源发现

    func testDiscoversDeclaredFeeds() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://blog.example.com/atom.xml'>
        <link rel="alternate" hreflang="en" href="/en/">
        </head></html>
        """
        let base = URL(string: "https://blog.example.com/posts/")!
        XCTAssertEqual(FeedDiscovery.feedLinks(inHTML: html, baseURL: base).map(\.absoluteString),
                       ["https://blog.example.com/feed.xml", "https://blog.example.com/atom.xml"])
    }

    func testNormalizesUserInput() {
        XCTAssertEqual(FeedDiscovery.normalizedURL(" sspai.com/feed ")?.absoluteString,
                       "https://sspai.com/feed")
        XCTAssertEqual(FeedDiscovery.normalizedURL("feed://example.com/rss")?.absoluteString,
                       "https://example.com/rss")
        XCTAssertNil(FeedDiscovery.normalizedURL("不是网址"))
        XCTAssertNil(FeedDiscovery.normalizedURL(""))
    }

    func testCandidatePathsKeepSubdirectory() {
        let urls = FeedDiscovery.candidateURLs(for: URL(string: "https://example.com/blog?x=1")!)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/blog/feed")
        XCTAssertTrue(urls.contains { $0.absoluteString == "https://example.com/blog/atom.xml" })
    }

    // MARK: - 检索与简报素材

    private let now = Date(timeIntervalSince1970: 1_783_501_200)

    private func entries() -> [NewsEntry] {
        [
            NewsEntry(feedTitle: "少数派", title: "苹果秋季发布会前瞻", summary: "新 iPhone 会有什么",
                      publishedAt: now.addingTimeInterval(-3600)),
            NewsEntry(feedTitle: "36氪", title: "电动车销量", summary: "苹果供应链也受影响",
                      publishedAt: now.addingTimeInterval(-7200), isRead: true),
            NewsEntry(feedTitle: "阮一峰", title: "科技爱好者周刊", summary: "本周分享",
                      publishedAt: now.addingTimeInterval(-3 * 86400)),
        ]
    }

    func testSearchRanksTitleHitsFirst() {
        let result = NewsPlan.search("苹果", in: entries())
        XCTAssertEqual(result.map(\.title), ["苹果秋季发布会前瞻", "电动车销量"])
    }

    func testSearchFallsBackToBigramsForUnspacedChinese() {
        // "苹果的发布会" 整词不在任何标题里,但切片"苹果""发布""布会"都命中第一条。
        XCTAssertEqual(NewsPlan.search("苹果的发布会", in: entries()).first?.title, "苹果秋季发布会前瞻")
        XCTAssertTrue(NewsPlan.search("量子计算", in: entries()).isEmpty)
    }

    func testEmptyQueryReturnsNewest() {
        XCTAssertEqual(NewsPlan.search("  ", in: entries(), limit: 2).map(\.title),
                       ["苹果秋季发布会前瞻", "电动车销量"])
    }

    func testDigestCandidatesPreferUnreadWithinWindow() {
        let picked = NewsPlan.digestCandidates(entries(), now: now)
        XCTAssertEqual(picked.map(\.title), ["苹果秋季发布会前瞻", "电动车销量"])
    }

    func testGroupByDayNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let groups = NewsPlan.groupByDay(entries(), calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.count, 2)
    }

    // MARK: - AI 解析

    func testParseArticleSummary() throws {
        let result = try DeepSeekClient.parseArticleSummary(
            ["summary": " 一句话 ", "points": ["a", "", 3, "b", "c", "d", "e", "f"]])
        XCTAssertEqual(result.summary, "一句话")
        XCTAssertEqual(result.points, ["a", "b", "c", "d", "e"])
        XCTAssertThrowsError(try DeepSeekClient.parseArticleSummary(["points": ["a"]]))
    }

    func testParseNewsDigest() throws {
        let digest = try DeepSeekClient.parseNewsDigest(
            ["overview": "今天很平静", "items": [["title": "A", "detail": "x", "source": "s"], ["detail": "缺标题"]]])
        XCTAssertEqual(digest.items, [.init(title: "A", detail: "x", source: "s")])
        XCTAssertThrowsError(try DeepSeekClient.parseNewsDigest(["items": []]))
    }

    func testSearchNewsToolIsGated() throws {
        let payload: [String: Any] = ["thought": "找订阅", "tool": "search_news", "query": "苹果"]
        guard case .toolCall(_, .searchNews(let query)) = try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, newsEnabled: true) else {
            return XCTFail("expected search_news")
        }
        XCTAssertEqual(query, "苹果")
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            payload, validUUIDs: [], memoryEnabled: false, newsEnabled: false))
    }

    func testNewsSkillOnlyInPromptWhenEnabled() {
        let off = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: .init()).system
        let on = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: .init(news: true)).system
        XCTAssertFalse(off.contains("search_news"))
        XCTAssertTrue(on.contains("search_news"))
    }

    func testBackupDecodesWithoutNewsFeeds() throws {
        let feed = BackupNewsFeed(uuid: UUID(), title: "t", url: "https://a.com/feed", siteURL: "",
                                  kind: "blog", enabled: true, createdAt: now)
        let data = try JSONEncoder().encode(feed)
        XCTAssertEqual(try JSONDecoder().decode(BackupNewsFeed.self, from: data).kind, "blog")
    }
}
