import Foundation
import SwiftData

/// 订阅源的类别。只影响新闻页顶上的筛选胶囊和列表里的小图标,抓取/解析是
/// 同一套(博客的订阅源本身也是 RSS/Atom)。**存储值 `news`/`blog` 别改**。
public enum NewsFeedKind: String, CaseIterable, Sendable {
    case news, blog

    public var title: String {
        switch self {
        case .news: return "新闻"
        case .blog: return "博客"
        }
    }

    public var symbol: String {
        switch self {
        case .news: return "newspaper"
        case .blog: return "text.book.closed"
        }
    }
}

/// 一个订阅源(RSS/Atom)。博客订阅时用户给的往往是博客首页,`NewsStore` 会从
/// 页面里找出真正的订阅地址再存进 `url`,`siteURL` 留着首页。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class NewsFeed {
    public var uuid: UUID = UUID()
    /// 显示名。订阅时取 feed 自己的标题,用户可以改。
    public var title: String = ""
    /// 订阅地址(RSS/Atom 的 xml)。
    public var url: String = ""
    /// 网站首页,点标题时打开;feed 里没有就空着。
    public var siteURL: String = ""
    public var kindRaw: String = NewsFeedKind.news.rawValue
    /// 停用 = 不再抓取,已经抓到的文章留着。
    public var enabled: Bool = true
    public var createdAt: Date = Date.now
    public var lastFetchedAt: Date?
    /// 上一次抓取失败的原因;成功就清掉。订阅管理页里如实显示。
    public var lastError: String?

    public init(uuid: UUID = UUID(), title: String, url: String, siteURL: String = "",
                kind: NewsFeedKind = .news, enabled: Bool = true, createdAt: Date = .now) {
        self.uuid = uuid
        self.title = title
        self.url = url
        self.siteURL = siteURL
        self.kindRaw = kind.rawValue
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public var kind: NewsFeedKind {
        get { NewsFeedKind(rawValue: kindRaw) ?? .news }
        set { kindRaw = newValue.rawValue }
    }
}

/// 抓到的一篇文章。只存标题、摘要(纯文本,截断过)和链接——正文每次要看时
/// 现抓,不把整站内容灌进数据库(文章量大,还要走 CloudKit)。
/// 和订阅源靠 `feedUUID` 关联,不建 SwiftData 关系(理由同 `MenuDish`)。
@Model
public final class NewsArticle {
    public var uuid: UUID = UUID()
    public var feedUUID: UUID = UUID()
    /// 冗余一份订阅源名字:列表每行都要显示,不用每行再查一次订阅源;
    /// 订阅源改名时 `NewsStore` 顺手改掉。
    public var feedTitle: String = ""
    /// 去重键:feed 里的 guid/id,没有就用链接(见 `ParsedFeedItem.dedupeKey`)。
    public var guid: String = ""
    public var link: String = ""
    public var title: String = ""
    /// feed 里给的摘要/正文,转成纯文本并截断(`NewsText.excerptLimit`)。
    public var summary: String = ""
    public var author: String = ""
    /// feed 没给发布时间时用抓到的时间。
    public var publishedAt: Date = Date.now
    public var fetchedAt: Date = Date.now
    public var isRead: Bool = false
    public var isStarred: Bool = false
    /// AI 总结(`DeepSeekClient.summarizeArticle` 的结果,JSON 见 `NewsArticleSummary`)。
    /// 总结过一次就留着,再打开不再花一次请求。
    public var aiSummaryData: Data?

    public init(uuid: UUID = UUID(), feedUUID: UUID, feedTitle: String, guid: String,
                link: String, title: String, summary: String = "", author: String = "",
                publishedAt: Date = .now, fetchedAt: Date = .now) {
        self.uuid = uuid
        self.feedUUID = feedUUID
        self.feedTitle = feedTitle
        self.guid = guid
        self.link = link
        self.title = title
        self.summary = summary
        self.author = author
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
    }

    public var aiSummary: NewsArticleSummary? {
        get { aiSummaryData.flatMap { try? JSONDecoder().decode(NewsArticleSummary.self, from: $0) } }
        set { aiSummaryData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// 纯逻辑层用的值快照(检索/排序/喂给 AI 都在 `NewsPlan` 里,不碰 SwiftData)。
    public var entry: NewsEntry {
        NewsEntry(uuid: uuid, feedTitle: feedTitle, title: title, summary: summary,
                  link: link, publishedAt: publishedAt, isRead: isRead, isStarred: isStarred)
    }
}

/// 一篇文章的 AI 总结:一段话 + 几条要点。
public struct NewsArticleSummary: Codable, Equatable, Sendable {
    public var summary: String
    public var points: [String]

    public init(summary: String, points: [String]) {
        self.summary = summary
        self.points = points
    }
}
