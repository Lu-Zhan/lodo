import Foundation
import SwiftData
import LodoCore

/// 新闻订阅的数据层:订阅(含博客首页 → 订阅地址的发现)、抓取、去重入库、清理,
/// 以及喂给 AI 的几段上下文(`search_news` 工具、定时推送、今日简报)。
///
/// 抓取只拿 feed 本身(标题/摘要/链接),**不抓正文**——正文在用户点「AI 总结」
/// 或 AI 对 链接 web_fetch 时才现抓,数据库和 CloudKit 里只有轻量的几列。
@MainActor
enum NewsStore {
    /// 距上次抓取不到这么久就不自动再抓(下拉刷新/订阅新源不受限)。
    static let staleInterval: TimeInterval = 30 * 60
    /// 没收藏的文章留多少天。
    static let retentionDays = 30
    /// 每个订阅源最多留多少篇(按发布时间,收藏的不算在内也不删)。
    static let perFeedLimit = 200
    nonisolated private static let requestTimeout: TimeInterval = 15

    enum SubscribeError: LocalizedError {
        case invalidURL
        case alreadySubscribed(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "请输入一个有效的网址。"
            case .alreadySubscribed(let title): return "已经订阅过「\(title)」了。"
            case .notFound: return "这个网址里没找到 RSS/Atom 订阅地址。可以试试直接填博客的 feed 地址(常见的是 /feed、/rss.xml、/atom.xml)。"
            }
        }
    }

    /// 推荐订阅:订阅管理页一键添加。只是起步用的几条,用户随时删。
    /// 36氪、阮一峰的博客实测对非浏览器请求返回反爬验证页(Cloudflare),不放进来。
    struct Preset: Identifiable {
        let title: String
        let url: String
        let kind: NewsFeedKind
        var id: String { url }
    }

    static let presets: [Preset] = [
        Preset(title: "少数派", url: "https://sspai.com/feed", kind: .news),
        Preset(title: "IT之家", url: "https://www.ithome.com/rss/", kind: .news),
        Preset(title: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml", kind: .news),
        Preset(title: "Hacker News", url: "https://hnrss.org/frontpage", kind: .news),
        Preset(title: "小众软件", url: "https://www.appinn.com/feed/", kind: .blog),
        Preset(title: "Simon Willison", url: "https://simonwillison.net/atom/everything/", kind: .blog),
        Preset(title: "Daring Fireball", url: "https://daringfireball.net/feeds/main", kind: .blog),
    ]

    // MARK: - 查询

    static func feeds(in context: ModelContext) -> [NewsFeed] {
        let descriptor = FetchDescriptor<NewsFeed>(sortBy: [SortDescriptor(\NewsFeed.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    static func articles(in context: ModelContext, feedUUID: UUID? = nil) -> [NewsArticle] {
        var descriptor = FetchDescriptor<NewsArticle>(
            sortBy: [SortDescriptor(\NewsArticle.publishedAt, order: .reverse)])
        if let feedUUID {
            descriptor.predicate = #Predicate { $0.feedUUID == feedUUID }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 订阅

    /// 订阅一个地址:可以是 feed 本身,也可以是博客/网站首页(从页面里找订阅地址)。
    /// 成功后立刻入库第一批文章。
    @discardableResult
    static func subscribe(_ input: String, kind: NewsFeedKind,
                          context: ModelContext) async throws -> NewsFeed {
        guard let url = FeedDiscovery.normalizedURL(input) else { throw SubscribeError.invalidURL }
        let existing = feeds(in: context)
        if let same = existing.first(where: { sameAddress($0.url, url.absoluteString) }) {
            throw SubscribeError.alreadySubscribed(same.title)
        }
        let (feedURL, parsed) = try await resolve(url)
        if let same = existing.first(where: { sameAddress($0.url, feedURL.absoluteString) }) {
            throw SubscribeError.alreadySubscribed(same.title)
        }
        let title = parsed.title.isEmpty ? (feedURL.host ?? feedURL.absoluteString) : parsed.title
        let site = parsed.siteURL.isEmpty && feedURL != url ? url.absoluteString : parsed.siteURL
        let feed = NewsFeed(title: title, url: feedURL.absoluteString, siteURL: site, kind: kind)
        context.insert(feed)
        feed.lastFetchedAt = Date()
        upsert(parsed.items, into: feed, context: context)
        try? context.save()
        return feed
    }

    /// 地址 → (真正的订阅地址, 解析结果)。先当 feed 读;是网页就按页面声明的
    /// 订阅地址、再按惯用路径逐个试,第一个能解析的就是。
    private static func resolve(_ url: URL) async throws -> (URL, ParsedFeed) {
        let data = try await fetch(url)
        if FeedDiscovery.looksLikeFeed(data) {
            return (url, try FeedParser.parse(data))
        }
        let html = String(decoding: data, as: UTF8.self)
        let declared = FeedDiscovery.feedLinks(inHTML: html, baseURL: url)
        for candidate in declared + FeedDiscovery.candidateURLs(for: url) {
            try Task.checkCancellation()
            guard let body = try? await fetch(candidate),
                  let parsed = try? FeedParser.parse(body) else { continue }
            return (candidate, parsed)
        }
        throw SubscribeError.notFound
    }

    private static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ text: String) -> String {
            var value = text.lowercased()
            for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count)
            }
            if value.hasPrefix("www.") { value.removeFirst(4) }
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return key(lhs) == key(rhs)
    }

    /// 删订阅:连同它的文章一起删,**收藏过的留着**(那是用户自己挑出来要留的,
    /// 订阅源名字冗余在文章上,删了源照样能显示)。
    static func delete(_ feed: NewsFeed, context: ModelContext) {
        for article in articles(in: context, feedUUID: feed.uuid) where !article.isStarred {
            context.delete(article)
        }
        context.delete(feed)
        try? context.save()
    }

    static func rename(_ feed: NewsFeed, to title: String, context: ModelContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != feed.title else { return }
        feed.title = trimmed
        for article in articles(in: context, feedUUID: feed.uuid) {
            article.feedTitle = trimmed
        }
        try? context.save()
    }

    // MARK: - 抓取

    /// 刷新全部启用的订阅源。force == false 时跳过最近刚抓过的(页面出现、定时推送前
    /// 调用);下拉刷新传 true。各源并发抓,解析在后台,入库回到主线程。
    static func refreshAll(context: ModelContext, force: Bool) async {
        let now = Date()
        let targets = feeds(in: context).filter { feed in
            guard feed.enabled else { return false }
            guard !force, let last = feed.lastFetchedAt else { return true }
            return now.timeIntervalSince(last) > staleInterval
        }
        guard !targets.isEmpty else { return }
        let jobs = targets.compactMap { feed in URL(string: feed.url).map { (feed.uuid, $0) } }
        let results = await withTaskGroup(of: (UUID, Result<ParsedFeed, Error>).self) { group in
            for (uuid, url) in jobs {
                group.addTask {
                    do {
                        let data = try await fetch(url)
                        return (uuid, .success(try FeedParser.parse(data)))
                    } catch {
                        return (uuid, .failure(error))
                    }
                }
            }
            var collected: [(UUID, Result<ParsedFeed, Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (uuid, result) in results {
            guard let feed = targets.first(where: { $0.uuid == uuid }) else { continue }
            feed.lastFetchedAt = now
            switch result {
            case .success(let parsed):
                feed.lastError = nil
                if feed.siteURL.isEmpty { feed.siteURL = parsed.siteURL }
                upsert(parsed.items, into: feed, context: context)
            case .failure(let error):
                // 取消(页面切走、后台时间用完)不算这个源坏了。
                if error is CancellationError || (error as? URLError)?.code == .cancelled { continue }
                feed.lastError = error.localizedDescription
            }
        }
        prune(context: context)
        try? context.save()
    }

    nonisolated private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        // 有些站点对不带 UA 的请求直接 403。
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) lodo/1.0",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"])
        }
        return data
    }

    /// 按去重键合并:已有的不动(保留已读/收藏/AI 总结),只插新的。
    /// 已有文章的标题/摘要也不跟着 feed 改——改了用户会以为读的是另一篇。
    private static func upsert(_ items: [ParsedFeedItem], into feed: NewsFeed, context: ModelContext) {
        let known = Set(articles(in: context, feedUUID: feed.uuid).map(\.guid))
        let now = Date()
        var seen = known
        for item in items {
            let key = item.dedupeKey
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            // 发布时间写在未来的(时区写错的 feed 很常见)按抓取时间算,免得一直钉在最上面。
            let published = min(item.published ?? now, now)
            context.insert(NewsArticle(
                feedUUID: feed.uuid, feedTitle: feed.title, guid: key, link: item.link,
                title: item.title.isEmpty ? item.link : item.title, summary: item.summary,
                author: item.author, publishedAt: published, fetchedAt: now))
        }
    }

    /// 清理:没收藏的超过 30 天删掉;每个源只留最新 200 篇。
    static func prune(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            ?? .distantPast
        var perFeed: [UUID: Int] = [:]
        for article in articles(in: context) where !article.isStarred {
            let count = (perFeed[article.feedUUID] ?? 0) + 1
            perFeed[article.feedUUID] = count
            if article.publishedAt < cutoff || count > perFeedLimit {
                context.delete(article)
            }
        }
    }

    // MARK: - 阅读状态

    static func setRead(_ article: NewsArticle, _ read: Bool, context: ModelContext) {
        guard article.isRead != read else { return }
        article.isRead = read
        try? context.save()
    }

    static func markAllRead(_ articles: [NewsArticle], context: ModelContext) {
        for article in articles where !article.isRead { article.isRead = true }
        try? context.save()
    }

    static func toggleStar(_ article: NewsArticle, context: ModelContext) {
        article.isStarred.toggle()
        try? context.save()
    }

    // MARK: - AI

    /// 本次运行里抓过的正文(按文章 uuid)。**不落库**:正文量大、还要走 CloudKit,
    /// 文章只存标题/摘要/链接(见 `NewsArticle`),重开 app 再抓一次。
    private static var fullTextCache: [UUID: String] = [:]

    /// 文章全文。很多 RSS 只给一两句摘要,这里去原网页抓,逐级退路:
    /// 1. 自己抓 HTML(带浏览器 UA,不少站对默认 UA 直接回 403/精简页),用
    ///    `ArticleExtractor` 挑正文;
    /// 2. 抽出来太短(常见于前端渲染的页面)时,在本机用不上屏的 WKWebView 把页面
    ///    真正渲染一遍再抽(`RenderedPageLoader`,非持久化数据存储);
    /// 3. 还不行就走公开的阅读服务 r.jina.ai——只把**文章链接**发过去,不带任何
    ///    用户数据;它对部分网络会拒绝匿名请求,失败就算了;
    /// 4. 都不行就用 feed 里的摘要。
    /// 只有比摘要长得多才算抓到,否则照样显示摘要。
    static func fullText(_ article: NewsArticle) async -> String? {
        if let cached = fullTextCache[article.uuid] { return cached }
        guard let url = URL(string: article.link), url.scheme?.hasPrefix("http") == true else { return nil }
        let threshold = max(ArticleExtractor.minimumLength, article.summary.count + 80)
        var text: String?
        if let html = await fetchHTML(url), let extracted = ArticleExtractor.mainText(fromHTML: html),
           extracted.count >= threshold {
            text = extracted
        } else if let html = await RenderedPageLoader.html(for: url),
                  let extracted = ArticleExtractor.mainText(fromHTML: html), extracted.count >= threshold {
            text = extracted
        } else if let reader = await fetchReader(url), reader.count >= threshold {
            text = reader
        }
        if let text { fullTextCache[article.uuid] = text }
        return text
    }

    nonisolated private static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    nonisolated private static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return ArticleExtractor.decode(data.prefix(3_000_000),
                                       contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    nonisolated private static func fetchReader(_ url: URL) async -> String? {
        guard let reader = URL(string: "https://r.jina.ai/" + url.absoluteString) else { return nil }
        var request = URLRequest(url: reader)
        request.timeoutInterval = 25
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = ArticleExtractor.cleanReaderMarkdown(String(decoding: data, as: UTF8.self))
        return text.isEmpty ? nil : text
    }

    /// 给 AI 总结用的正文:能抓到全文用全文,否则退回 feed 摘要。
    static func articleText(_ article: NewsArticle) async -> String {
        if let text = await fullText(article) { return MemorySearch.truncate(text) }
        return article.summary.isEmpty ? article.title : article.summary
    }

    static func summarize(_ article: NewsArticle, language: AppLanguage,
                          context: ModelContext) async throws -> NewsArticleSummary {
        if let cached = article.aiSummary { return cached }
        let text = await articleText(article)
        try Task.checkCancellation()
        let result = try await DeepSeekClient.summarizeArticle(
            title: article.title, source: article.feedTitle, text: text,
            language: MenuStore.targetLanguageName(language))
        article.aiSummary = result
        try? context.save()
        return result
    }

    /// `search_news` 工具的观察结果。
    static func searchObservation(_ query: String, context: ModelContext) -> String {
        guard !feeds(in: context).isEmpty else { return "用户还没有订阅任何新闻或博客" }
        let hits = NewsPlan.search(query, in: articles(in: context).map(\.entry))
        guard !hits.isEmpty else {
            return query.isEmpty ? "订阅里还没有抓到文章" : "订阅的文章里没有找到和「\(query)」相关的内容"
        }
        return NewsPlan.promptLines(hits)
    }

    /// 定时推送 / 今日简报的素材;没有启用中的订阅或没有近期文章时为 nil。
    /// **停用的订阅不参与**:停用不只是"不再抓",它已经抓到的近期文章也不进简报——
    /// 用户停用一个源,就是不想再在推送里看到它。(`search_news` 不受影响,
    /// 问 AI 找文章时照样能搜到停用源里已有的文章。)
    static func digestContext(context: ModelContext) -> String? {
        let enabled = Set(feeds(in: context).filter(\.enabled).map(\.uuid))
        let picked = NewsPlan.digestCandidates(
            articles(in: context).filter { enabled.contains($0.feedUUID) }.map(\.entry))
        guard !picked.isEmpty else { return nil }
        return NewsPlan.promptLines(picked, summaryLength: 80)
    }

    // MARK: - 今日简报缓存

    /// 按天缓存一份(同总览页 AI 段落的口径):当天再打开直接显示,想要新的点刷新。
    /// 纯展示用的派生数据,存本机 UserDefaults,不进数据库也不备份。
    private static let digestKey = "news.digest.cache"

    private struct DigestCache: Codable {
        var day: Date
        var generatedAt: Date
        var digest: NewsDigest
    }

    static func cachedDigest() -> (digest: NewsDigest, generatedAt: Date)? {
        guard let data = UserDefaults.standard.data(forKey: digestKey),
              let cache = try? JSONDecoder().decode(DigestCache.self, from: data),
              Calendar.current.isDateInToday(cache.day) else { return nil }
        return (cache.digest, cache.generatedAt)
    }

    static func generateDigest(language: AppLanguage,
                               context: ModelContext) async throws -> NewsDigest? {
        guard let headlines = digestContext(context: context) else { return nil }
        let digest = try await DeepSeekClient.newsDigest(
            headlines: headlines, language: MenuStore.targetLanguageName(language))
        let now = Date()
        let cache = DigestCache(day: Calendar.current.startOfDay(for: now), generatedAt: now, digest: digest)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: digestKey)
        }
        return digest
    }
}
