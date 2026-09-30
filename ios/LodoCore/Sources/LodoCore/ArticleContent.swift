import Foundation

/// 文章详情页"阅读模式"排版用的正文结构:按原文顺序排好的标题、段落、引用、
/// 列表项和图片(纯逻辑,`ArticleContentTests`)。
///
/// `ArticleExtractor.mainText` 只给纯文本(AI 总结用);阅读页要分段、要图片,
/// 所以这里按原网页的块级元素顺序再走一遍。挑正文区域的思路和它一样:最长的
/// `<article>`,没有就整页去掉导航/页眉页脚/侧栏之后的部分。
public enum ArticleBlock: Equatable, Hashable, Sendable {
    case heading(String)
    case paragraph(String)
    case quote(String)
    case listItem(String)
    case image(URL)
}

public struct ArticleContent: Equatable, Sendable {
    public var blocks: [ArticleBlock]

    public init(blocks: [ArticleBlock]) {
        self.blocks = blocks
    }

    /// 纯文本(AI 总结、长度判断用):文字块按行拼起来,图片不算。
    public var text: String {
        blocks.compactMap { block -> String? in
            switch block {
            case .heading(let t), .paragraph(let t), .quote(let t), .listItem(let t): return t
            case .image: return nil
            }
        }.joined(separator: "\n")
    }

    public var imageCount: Int {
        blocks.filter { if case .image = $0 { return true } else { return false } }.count
    }

    /// 纯文本退化成段落(JSON-LD 的 articleBody、抽不出结构时):一行一段。
    public init(plainText: String, images: [URL] = []) {
        let paragraphs = plainText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(ArticleBlock.paragraph)
        // 结构抽不出来时图片没有准确位置:第一张放在开头(多半是题图),其余放在最后。
        var blocks = paragraphs
        if let first = images.first { blocks.insert(.image(first), at: 0) }
        blocks += images.dropFirst().map(ArticleBlock.image)
        self.blocks = blocks
    }

    /// 同一张图最多出现一次(懒加载的站常把同一张图写两遍)。
    public static let maximumImages = 30
}

extension ArticleExtractor {
    /// 从网页 HTML 抽阅读模式正文。结构化抽出来的文字够长就用它;不够时用
    /// `mainText` 的纯文本分段,再把抽到的图片挂上。都没有时返回 nil。
    public static func content(fromHTML html: String, baseURL: URL?) -> ArticleContent? {
        let region = contentRegion(html)
        let structured = blocks(fromHTML: region, baseURL: baseURL)
        let structuredContent = ArticleContent(blocks: structured)
        if structuredContent.text.count >= minimumLength {
            return trimmed(structuredContent)
        }
        guard let text = mainText(fromHTML: html) else { return nil }
        let images = structured.compactMap { block -> URL? in
            if case .image(let url) = block { return url } else { return nil }
        }
        return trimmed(ArticleContent(plainText: text, images: images))
    }

    /// r.jina.ai 返回的 Markdown → 结构:`![](url)` 是图片,`#` 开头是小标题,
    /// `>` 是引用,`-`/`*`/`1.` 是列表项,其余每行一段。
    public static func content(fromReaderMarkdown markdown: String, baseURL: URL?) -> ArticleContent? {
        var text = markdown
        if let range = text.range(of: "Markdown Content:") {
            text = String(text[range.upperBound...])
        }
        var blocks: [ArticleBlock] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.range(of: "^[=\\-*_]{3,}$", options: .regularExpression) != nil { continue }
            // 一行里的图片先拿出来(可能和文字写在同一行)。
            for src in markdownImages(line) {
                if let url = resolve(src, base: baseURL) { blocks.append(.image(url)) }
            }
            var rest = line.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "",
                                                 options: .regularExpression)
            rest = rest.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1",
                                             options: .regularExpression)
            rest = rest.replacingOccurrences(of: "\\*\\*|__", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            if rest.hasPrefix("#") {
                let heading = rest.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { blocks.append(.heading(heading)) }
            } else if rest.hasPrefix(">") {
                let quote = rest.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces)
                if !quote.isEmpty { blocks.append(.quote(quote)) }
            } else if let range = rest.range(of: "^([-*+]|\\d+[.)])\\s+", options: .regularExpression) {
                blocks.append(.listItem(String(rest[range.upperBound...])))
            } else {
                blocks.append(.paragraph(rest))
            }
        }
        let content = trimmed(ArticleContent(blocks: blocks))
        return content.text.isEmpty ? nil : content
    }

    // MARK: - 区域与块

    /// 正文所在的那一段 HTML:最长的 `<article>`(按纯文本长度),没有就整页去噪声。
    static func contentRegion(_ html: String) -> String {
        let cleaned = html.replacingOccurrences(
            of: "(?is)<(script|style|noscript|nav|header|footer|aside|form|svg|button)[^>]*>.*?</\\1>",
            with: " ", options: .regularExpression)
        .replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        let articles = matches("(?is)<article[^>]*>(.*?)</article>", in: cleaned)
        if let longest = articles.max(by: {
            NewsText.plainText(fromHTML: $0).count < NewsText.plainText(fromHTML: $1).count
        }), NewsText.plainText(fromHTML: longest).count >= minimumLength {
            return longest
        }
        if let body = matches("(?is)<body[^>]*>(.*)</body>", in: cleaned).first { return body }
        return cleaned
    }

    /// 按出现顺序扫块级元素。`<p>`/`<li>`/`<figure>` 里夹着的图片先于文字放出来。
    static func blocks(fromHTML region: String, baseURL: URL?) -> [ArticleBlock] {
        let pattern = "(?is)<(h[1-6])[^>]*>(.*?)</\\1>"
            + "|<(blockquote)[^>]*>(.*?)</blockquote>"
            + "|<(figure)[^>]*>(.*?)</figure>"
            + "|<(p)[^>]*>(.*?)</p>"
            + "|<(li)[^>]*>(.*?)</li>"
            + "|(<img[^>]*>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [ArticleBlock] = []
        let range = NSRange(region.startIndex..., in: region)
        for match in regex.matches(in: region, range: range) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: region).map { String(region[$0]) }
            }
            if let tag = group(1), let inner = group(2) {
                appendImages(in: inner, base: baseURL, to: &result)
                let text = inlineText(inner)
                if !text.isEmpty {
                    // h1 多半是页面标题(详情页顶上已经有了),正文里只认 h2 以下。
                    if tag.lowercased() != "h1" { result.append(.heading(text)) }
                }
            } else if let inner = group(4) {
                appendImages(in: inner, base: baseURL, to: &result)
                let text = inlineText(inner)
                if !text.isEmpty { result.append(.quote(text)) }
            } else if let inner = group(6) {
                // figure:图片 + 图注。图注当普通小段落,不单独成类。
                appendImages(in: inner, base: baseURL, to: &result)
            } else if let inner = group(8) {
                appendImages(in: inner, base: baseURL, to: &result)
                let text = inlineText(inner)
                if isBodyText(text) { result.append(.paragraph(text)) }
            } else if let inner = group(10) {
                appendImages(in: inner, base: baseURL, to: &result)
                let text = inlineText(inner)
                if isBodyText(text) { result.append(.listItem(text)) }
            } else if let tag = group(11) {
                if let url = imageURL(tag, base: baseURL) { result.append(.image(url)) }
            }
        }
        return result
    }

    /// 很短的一行多半是按钮、署名、"相关阅读"这类,不算正文。
    private static func isBodyText(_ text: String) -> Bool {
        text.count >= 2 && !["分享", "评论", "点赞", "收藏", "Share", "Comments"].contains(text)
    }

    /// 段落里的行内标签去掉、实体解码、空白折叠(段落内不保留换行)。
    static func inlineText(_ html: String) -> String {
        NewsText.collapse(NewsText.plainText(fromHTML: html))
    }

    private static func appendImages(in html: String, base: URL?, to result: inout [ArticleBlock]) {
        for tag in matches("(?is)(<img[^>]*>)", in: html) {
            if let url = imageURL(tag, base: base) { result.append(.image(url)) }
        }
    }

    /// `<img>` 的真实地址:懒加载的站把真图放在 data-src / data-original 里,src
    /// 只是一张占位图,所以这几个优先。小图标、1 像素统计图、data: 内联图都不要。
    static func imageURL(_ tag: String, base: URL?) -> URL? {
        for attribute in ["data-src", "data-original", "data-lazy-src", "data-actualsrc", "src"] {
            guard let value = attributeValue(attribute, in: tag), !value.isEmpty,
                  !value.hasPrefix("data:") else { continue }
            let lower = value.lowercased()
            if lower.hasSuffix(".svg") || lower.contains("pixel") || lower.contains("spacer")
                || lower.contains("/emoji/") || lower.contains("avatar") { return nil }
            if let width = attributeValue("width", in: tag).flatMap({ Int($0) }), width < 80 { return nil }
            if let height = attributeValue("height", in: tag).flatMap({ Int($0) }), height < 60 { return nil }
            return resolve(value, base: base)
        }
        return nil
    }

    static func attributeValue(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?is)\\s\(escaped)\\s*=\\s*[\"']([^\"']*)[\"']"
        return matches(pattern, in: tag).first.map { NewsText.plainText(fromHTML: $0) }
    }

    /// 相对地址按文章链接补全;`//cdn…` 补 https。只认 http/https。
    static func resolve(_ value: String, base: URL?) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: absolute, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        // ATS 不放行明文 http 图片,能升级的直接换成 https。
        if scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            return components.url
        }
        return url
    }

    private static func markdownImages(_ line: String) -> [String] {
        matches("!\\[[^\\]]*\\]\\(([^)\\s]+)[^)]*\\)", in: line)
    }

    /// 连续好几个很短的列表项,多半是导航、归档年份、标签云(没有 `<article>` 的页面
    /// 整页扫时会混进来),整串去掉。正文里的要点列表每项通常长得多。
    static let navigationListRun = 3
    static let navigationItemLength = 12

    static func droppingNavigationLists(_ blocks: [ArticleBlock]) -> [ArticleBlock] {
        var result: [ArticleBlock] = []
        var run: [ArticleBlock] = []
        func flush() {
            if run.count < navigationListRun { result += run }
            run = []
        }
        for block in blocks {
            if case .listItem(let text) = block, text.count <= navigationItemLength {
                run.append(block)
            } else {
                flush()
                result.append(block)
            }
        }
        flush()
        return result
    }

    /// 正文到这类小标题就结束了:后面是"相关阅读""更多文章""订阅我们"这些站点自己的东西。
    static let tailHeadingPattern =
        "(?i)^(相关|推荐|延伸|热门|更多|猜你|往期|最新)(阅读|文章|推荐|内容|新闻|喜欢)?|"
        + "^(more|related|recent|popular|further|you may|you might|read more|"
        + "recommended|monthly briefing|newsletter|subscribe|comments?)\\b"

    /// 在第一个"尾巴"小标题处截断(前面至少得有一段正文,免得把整篇截没了)。
    static func cuttingTail(_ blocks: [ArticleBlock]) -> [ArticleBlock] {
        var sawParagraph = false
        for (index, block) in blocks.enumerated() {
            switch block {
            case .paragraph: sawParagraph = true
            case .heading(let text):
                if sawParagraph, text.range(of: tailHeadingPattern, options: .regularExpression) != nil {
                    return Array(blocks[..<index])
                }
            default: break
            }
        }
        return blocks
    }

    /// 截掉尾巴、去掉导航式短列表、去重相邻的同样文字、同一张图只留第一次、总长截断。
    static func trimmed(_ content: ArticleContent) -> ArticleContent {
        var seenImages = Set<URL>()
        var result: [ArticleBlock] = []
        var length = 0
        for block in droppingNavigationLists(cuttingTail(content.blocks)) {
            if case .image(let url) = block {
                guard seenImages.count < ArticleContent.maximumImages,
                      seenImages.insert(url).inserted else { continue }
            } else if let last = result.last, last == block {
                continue
            }
            result.append(block)
            if case .image = block { continue }
            length += ArticleContent(blocks: [block]).text.count
            if length >= maximumLength { break }
        }
        return ArticleContent(blocks: result)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
