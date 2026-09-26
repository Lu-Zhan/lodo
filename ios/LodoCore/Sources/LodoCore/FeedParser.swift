import Foundation

/// 解析出来的一个订阅源(RSS 2.0 / RSS 1.0(RDF) / Atom 三种都认)。
public struct ParsedFeed: Equatable, Sendable {
    public var title: String
    /// 网站首页(RSS 的 channel/link,Atom 的 rel=alternate 链接)。
    public var siteURL: String
    public var items: [ParsedFeedItem]

    public init(title: String, siteURL: String, items: [ParsedFeedItem]) {
        self.title = title
        self.siteURL = siteURL
        self.items = items
    }
}

public struct ParsedFeedItem: Equatable, Sendable {
    public var guid: String
    public var title: String
    public var link: String
    /// 纯文本、已截断的摘要。
    public var summary: String
    public var author: String
    /// feed 里没有或认不出来时为 nil,由调用方用抓取时间兜底。
    public var published: Date?

    public init(guid: String, title: String, link: String, summary: String,
                author: String, published: Date?) {
        self.guid = guid
        self.title = title
        self.link = link
        self.summary = summary
        self.author = author
        self.published = published
    }

    /// 去重键:guid 优先(它就是为这个设计的),没有就用链接,再没有用标题。
    /// 有的 feed 每次改文章都会换 guid,那种只能认了,不去猜。
    public var dedupeKey: String {
        for candidate in [guid, link, title] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

public enum FeedParseError: LocalizedError, Equatable {
    /// 能读但不是 RSS/Atom(多半是网页,交给 `FeedDiscovery` 找订阅地址)。
    case notAFeed
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notAFeed: return "这不是 RSS/Atom 订阅地址"
        case .malformed(let reason): return "订阅内容解析失败:\(reason)"
        }
    }
}

/// RSS/Atom → `ParsedFeed`。用系统 `XMLParser`(Foundation 自带,三个平台都有),
/// 不引第三方库。不处理命名空间,直接按带前缀的元素名匹配(`content:encoded`、
/// `dc:creator`)——绝大多数 feed 都用这几个惯用前缀。
public enum FeedParser {
    /// 单个订阅源最多保留多少条(按 feed 自己的顺序,通常是新的在前)。
    public static let maxItems = 60

    public static func parse(_ data: Data) throws -> ParsedFeed {
        guard FeedDiscovery.looksLikeFeed(data) else { throw FeedParseError.notAFeed }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        // 很多 feed 在最后几条之后有些小毛病(未转义的 &、截断);前面已经解析出来的
        // 条目照样能用,只有一条都没拿到时才算失败。
        if !ok && delegate.items.isEmpty {
            throw FeedParseError.malformed(parser.parserError?.localizedDescription ?? "未知错误")
        }
        guard delegate.sawRoot else { throw FeedParseError.notAFeed }
        let items = delegate.items
            .filter { !$0.title.isEmpty || !$0.link.isEmpty }
            .prefix(maxItems)
        return ParsedFeed(title: NewsText.collapse(delegate.feedTitle),
                          siteURL: delegate.siteURL.trimmingCharacters(in: .whitespacesAndNewlines),
                          items: Array(items))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawRoot = false
        var feedTitle = ""
        var siteURL = ""
        var items: [ParsedFeedItem] = []

        private var stack: [String] = []
        private var buffer = ""
        private var current: ItemDraft?

        private struct ItemDraft {
            var guid = ""
            var title = ""
            var link = ""
            var summary = ""
            var content = ""
            var author = ""
            var published: Date?
            var updated: Date?
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes: [String: String] = [:]) {
            let name = elementName.lowercased()
            if ["rss", "feed", "rdf:rdf"].contains(name) { sawRoot = true }
            stack.append(name)
            buffer = ""
            if name == "item" || name == "entry" {
                current = ItemDraft()
                return
            }
            // Atom 的链接在属性里:<link rel="alternate" href="…"/>(rel 缺省就是 alternate)。
            if name == "link", let href = attributes["href"] {
                let rel = attributes["rel"]?.lowercased() ?? "alternate"
                guard rel == "alternate" else { return }
                if current != nil {
                    if current?.link.isEmpty == true { current?.link = href }
                } else if siteURL.isEmpty {
                    siteURL = href
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let name = elementName.lowercased()
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            defer { if !stack.isEmpty { stack.removeLast() } }
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

            if name == "item" || name == "entry" {
                if let draft = current { items.append(finish(draft)) }
                current = nil
                return
            }

            guard current != nil else {
                // 订阅源本身的字段:只认 channel/feed 的直接子元素,
                // 免得把 <image><title> 之类当成站名。
                guard parent == "channel" || parent == "feed" else { return }
                if name == "title", feedTitle.isEmpty { feedTitle = text }
                if name == "link", siteURL.isEmpty, !text.isEmpty { siteURL = text }
                return
            }

            switch name {
            case "title" where parent == "item" || parent == "entry":
                if current!.title.isEmpty { current!.title = NewsText.plainText(fromHTML: text) }
            case "link":
                if current!.link.isEmpty, !text.isEmpty { current!.link = text }
            case "guid", "id":
                if current!.guid.isEmpty { current!.guid = text }
            case "description", "summary":
                if current!.summary.isEmpty { current!.summary = text }
            case "content:encoded", "content":
                if current!.content.isEmpty { current!.content = text }
            case "pubdate", "published", "dc:date", "issued":
                if current!.published == nil { current!.published = FeedDate.parse(text) }
            case "updated", "modified":
                if current!.updated == nil { current!.updated = FeedDate.parse(text) }
            case "dc:creator":
                if current!.author.isEmpty { current!.author = text }
            case "name" where parent == "author":
                if current!.author.isEmpty { current!.author = text }
            case "author":
                // RSS 的 <author> 是纯文本(常见 "mail@x.com (名字)");Atom 的
                // <author> 里包着 <name>,那时这里拿到的 text 是空的。
                if current!.author.isEmpty, !text.isEmpty { current!.author = text }
            default:
                break
            }
        }

        private func finish(_ draft: ItemDraft) -> ParsedFeedItem {
            // 摘要优先 description/summary(本来就是摘要),没有才从正文里截。
            let source = draft.summary.isEmpty ? draft.content : draft.summary
            return ParsedFeedItem(
                guid: draft.guid,
                title: NewsText.collapse(draft.title),
                link: draft.link.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: NewsText.excerpt(NewsText.plainText(fromHTML: source)),
                author: NewsText.collapse(draft.author),
                published: draft.published ?? draft.updated)
        }
    }
}

/// feed 里的日期:RSS 是 RFC 822(`Wed, 08 Jul 2026 09:00:00 +0800`,时区写法
/// 五花八门),Atom 是 ISO 8601。认不出来返回 nil。
public enum FeedDate {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy",
    ]

    private static let formatters: [DateFormatter] = rfc822Formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = isoFractional.date(from: text) ?? iso.date(from: text) { return date }
        // 有的 feed 把 GMT/UT 写成别的样子,或者在星期后面多一个空格。
        let normalized = text
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " UT$", with: " GMT", options: .regularExpression)
        for formatter in formatters {
            if let date = formatter.date(from: normalized) { return date }
        }
        if text.count == 10, let date = isoDay.date(from: text) { return date }
        return nil
    }
}

/// HTML → 纯文本,以及摘要截断。不用 NSAttributedString 的 HTML 导入:那条路
/// 只能在主线程跑、而且要起 WebKit,解析几十条摘要用它太重。
public enum NewsText {
    /// 存进库里的摘要最多这么多字。
    public static let excerptLimit = 600

    public static func plainText(fromHTML html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return collapse(html) }
        var text = html
        // 脚本、样式整块去掉(里面的文字不是给人看的)。
        text = text.replacingOccurrences(
            of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        // 块级标签换成换行,段落之间不至于粘在一起。
        text = text.replacingOccurrences(
            of: "(?i)<(br|/p|/div|/li|/h[1-6]|/blockquote|/tr)[^>]*>", with: "\n",
            options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        return collapse(text, keepNewlines: true)
    }

    /// 连续空白折叠成一个空格;keepNewlines 时保留(折叠过的)换行。
    public static func collapse(_ text: String, keepNewlines: Bool = false) -> String {
        if !keepNewlines {
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func excerpt(_ text: String, limit: Int = excerptLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "middot": "·", "copy": "©", "reg": "®",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            guard char == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(char)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst())
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[name.lowercased()]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(char)
                index = text.index(after: index)
            }
        }
        return result
    }
}

/// 博客订阅:用户给的通常是博客首页而不是订阅地址。先看它本身是不是 feed,
/// 不是的话从 HTML 的 `<link rel="alternate" type="application/rss+xml">` 里找;
/// 页面没声明时再按几个惯用路径试(`candidateURLs`)。
public enum FeedDiscovery {
    /// 用户输入 → 规范化的 URL:没写协议补 https,去掉首尾空白。
    public static func normalizedURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.hasPrefix("feed://") { text = "https://" + text.dropFirst("feed://".count) }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.host?.contains(".") == true else { return nil }
        return url
    }

    /// 只看开头一段,判断是不是 RSS/Atom(不是的话多半是网页)。
    public static func looksLikeFeed(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }

    /// 从网页 HTML 里找声明的订阅地址,按页面里出现的顺序,相对地址按 base 补全。
    public static func feedLinks(inHTML html: String, baseURL: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result: [URL] = []
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard rel.split(separator: " ").contains("alternate"),
                  type.contains("rss") || type.contains("atom"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: NewsText.decodeEntities(href), relativeTo: baseURL)?.absoluteURL,
                  !result.contains(url) else { continue }
            result.append(url)
        }
        return result
    }

    /// 页面没声明订阅地址时按惯用路径去试(WordPress/Hugo/Hexo/Jekyll/Ghost 等)。
    public static func candidateURLs(for site: URL) -> [URL] {
        let paths = ["feed", "rss", "rss.xml", "atom.xml", "feed.xml", "index.xml"]
        guard var components = URLComponents(url: site, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil
        components.fragment = nil
        var base = components.path
        if !base.hasSuffix("/") { base += "/" }
        return paths.compactMap { path in
            var copy = components
            copy.path = base + path
            return copy.url
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range])
            }
        }
        return nil
    }
}
