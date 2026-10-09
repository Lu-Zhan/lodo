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
    /// `numbered`:每行用「[编号]」开头(1 起),今日简报要模型按编号回引参考文章。
    public static func promptLines(_ entries: [NewsEntry], summaryLength: Int = 120,
                                   numbered: Bool = false,
                                   calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return entries.enumerated().map { index, entry in
            let bullet = numbered ? "[\(index + 1)]" : "-"
            var line = "\(bullet) [\(entry.feedTitle)] \(entry.title)(\(formatter.string(from: entry.publishedAt)))"
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
        /// 模型给的参考文章编号(清单里的 1、2、3…,见 `NewsPlan.promptLines(numbered:)`)。
        /// 老缓存没有这个 key,所以是 Optional(合成的 Decodable 对 Optional 走 decodeIfPresent)。
        public var refs: [Int]?
        /// 编号换算成的文章 uuid(`NewsStore.generateDigest` 填):「今日」里每条下面
        /// 挂的参考新闻链接,点了进那篇文章。
        public var articleIDs: [UUID]?

        public init(title: String, detail: String, source: String,
                    refs: [Int]? = nil, articleIDs: [UUID]? = nil) {
            self.title = title
            self.detail = detail
            self.source = source
            self.refs = refs
            self.articleIDs = articleIDs
        }
    }

    /// 把每条的参考编号(1 起)换算成清单里对应文章的 uuid;越界的编号丢掉、
    /// 重复的只留一次。
    public func resolvingReferences(_ candidates: [NewsEntry]) -> NewsDigest {
        var copy = self
        copy.items = items.map { item in
            var item = item
            var seen = Set<UUID>()
            item.articleIDs = (item.refs ?? []).compactMap { number in
                guard number >= 1, number <= candidates.count else { return nil }
                let id = candidates[number - 1].uuid
                return seen.insert(id).inserted ? id : nil
            }
            return item
        }
        return copy
    }

    public var overview: String
    public var items: [Item]

    public init(overview: String, items: [Item]) {
        self.overview = overview
        self.items = items
    }
}

/// 按内容主题整理的简报。类别由模型根据当天文章生成，名称供顶部筛选使用。
public struct NewsCategoryDigest: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var digest: NewsDigest
    public var id: String { name }

    public init(name: String, digest: NewsDigest) {
        self.name = name
        self.digest = digest
    }
}
