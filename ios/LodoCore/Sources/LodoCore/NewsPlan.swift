import Foundation

/// 一篇文章的值快照(`NewsArticle.entry`)。检索、分组、拼 prompt 都在这一层做,
/// 单测不碰 SwiftData(同 `TravelEntry` ↔ `MemoryItem` 的分层)。
public struct NewsEntry: Equatable, Sendable, Identifiable {
    public var uuid: UUID
    public var feedTitle: String
    public var title: String
    public var summary: String
    public var link: String
    public var publishedAt: Date
    public var isRead: Bool
    public var isStarred: Bool

    public var id: UUID { uuid }

    public init(uuid: UUID = UUID(), feedTitle: String, title: String, summary: String = "",
                link: String = "", publishedAt: Date, isRead: Bool = false, isStarred: Bool = false) {
        self.uuid = uuid
        self.feedTitle = feedTitle
        self.title = title
        self.summary = summary
        self.link = link
        self.publishedAt = publishedAt
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

public enum NewsPlan {
    /// 按天分组(新的一天在前,组内新的在前)。
    public static func groupByDay(_ entries: [NewsEntry],
                                  calendar: Calendar = .current) -> [(day: Date, entries: [NewsEntry])] {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.publishedAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.publishedAt > $1.publishedAt })
        }
    }

    /// 关键词检索(`search_news` 工具与新闻页共用)。标题命中权重高于摘要;
    /// 中文查询词常常整句不带空格("苹果发布会"),整词匹配不上时退回按两字切片,
    /// 命中一半以上的切片才算。空查询返回最新的几条(模型问"最近有什么新闻"时)。
    public static func search(_ query: String, in entries: [NewsEntry], limit: Int = 12) -> [NewsEntry] {
        let newestFirst = entries.sorted { $0.publishedAt > $1.publishedAt }
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters).union(.symbols))
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return Array(newestFirst.prefix(limit)) }

        func score(_ entry: NewsEntry, terms: [String], minimumHits: Int) -> Int {
            let title = entry.title.lowercased()
            let body = (entry.summary + " " + entry.feedTitle).lowercased()
            var total = 0
            var hits = 0
            for term in terms {
                if title.contains(term) { total += 3; hits += 1 } else if body.contains(term) { total += 1; hits += 1 }
            }
            return hits >= minimumHits ? total : 0
        }

        func ranked(terms: [String], minimumHits: Int) -> [NewsEntry] {
            newestFirst
                .map { ($0, score($0, terms: terms, minimumHits: minimumHits)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }   // 同分保持新的在前(sorted 是稳定的)
                .prefix(limit)
                .map(\.0)
        }

        let direct = ranked(terms: terms, minimumHits: 1)
        if !direct.isEmpty { return direct }
        let grams = terms.flatMap(bigrams)
        guard grams.count > 1 else { return [] }
        return ranked(terms: grams, minimumHits: (grams.count + 1) / 2)
    }

    private static func bigrams(_ term: String) -> [String] {
        let chars = Array(term)
        guard chars.count > 2 else { return [term] }
        return (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
    }

    /// 喂给模型的文章清单:一行一篇,带来源、时间、摘要开头和链接。
    /// 摘要只取开头一段——模型要的是"有什么",细节它可以再 web_fetch 那条链接。
    public static func promptLines(_ entries: [NewsEntry], summaryLength: Int = 120,
                                   calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return entries.map { entry in
            var line = "- [\(entry.feedTitle)] \(entry.title)(\(formatter.string(from: entry.publishedAt)))"
            let summary = NewsText.excerpt(NewsText.collapse(entry.summary), limit: summaryLength)
            if !summary.isEmpty, summary != entry.title { line += ":\(summary)" }
            if !entry.link.isEmpty { line += "\n  链接:\(entry.link)" }
            return line
        }.joined(separator: "\n")
    }

    /// 简报/定时推送用的素材:最近 `hours` 小时内的文章,没读过的优先,
    /// 不够时拿最近读过的补上(用户早上刷过一遍,晚上的简报不该因此空着)。
    public static func digestCandidates(_ entries: [NewsEntry], now: Date = Date(),
                                        hours: Int = 24, limit: Int = 40) -> [NewsEntry] {
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        let recent = entries.filter { $0.publishedAt >= cutoff && $0.publishedAt <= now.addingTimeInterval(3600) }
            .sorted { $0.publishedAt > $1.publishedAt }
        let unread = recent.filter { !$0.isRead }
        let read = recent.filter(\.isRead)
        return Array((unread + read).prefix(limit))
    }
}

/// 新闻页顶部的「今日简报」(`DeepSeekClient.newsDigest`)。按天缓存成 JSON,
/// 所以是 Codable。
public struct NewsDigest: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        public var detail: String
        public var source: String

        public init(title: String, detail: String, source: String) {
            self.title = title
            self.detail = detail
            self.source = source
        }
    }

    public var overview: String
    public var items: [Item]

    public init(overview: String, items: [Item]) {
        self.overview = overview
        self.items = items
    }
}
