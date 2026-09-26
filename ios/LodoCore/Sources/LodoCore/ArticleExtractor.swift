import Foundation

/// 从文章网页的 HTML 里抽正文(纯逻辑,`ArticleExtractorTests`)。
///
/// 很多 RSS 只给一两句摘要,正文要去原网页抓。整页 HTML → 纯文本会把导航、
/// 推荐阅读、页脚一起带进来,这里按常见的"可读性"思路挑正文:
/// 1. JSON-LD 里的 `articleBody`(新闻站为了搜索引擎普遍会写,最干净);
/// 2. 最长的那个 `<article>`(优先取里面的段落);
/// 3. 页面里所有像样的 `<p>`(去掉很短的——按钮文字、版权行);
/// 4. 都没有时退回 `og:description` / `description`。
/// 不追求完美,只要比 feed 里那两句多、又不混进一堆导航就够 AI 总结和阅读了。
public enum ArticleExtractor {
    /// 抽出来的正文少于这么多字就当作没抽到。
    public static let minimumLength = 120
    /// 存/显示的上限(太长的页面截断,AI 那边另有自己的截断)。
    public static let maximumLength = 20_000

    public static func mainText(fromHTML html: String) -> String? {
        for candidate in [jsonLDBody(html), longestArticle(html), paragraphs(html)] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.count >= minimumLength {
                return cap(text)
            }
        }
        return metaDescription(html).map(cap)
    }

    private static func cap(_ text: String) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength)) + "…" : text
    }

    static func jsonLDBody(_ html: String) -> String? {
        let pattern = "(?is)<script[^>]*application/ld\\+json[^>]*>(.*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var best: String?
        for match in regex.matches(in: html, range: range) {
            guard let r = Range(match.range(at: 1), in: html),
                  let data = String(html[r]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let body = findArticleBody(json) {
                let text = NewsText.plainText(fromHTML: body)
                if text.count > (best?.count ?? 0) { best = text }
            }
        }
        return best
    }

    private static func findArticleBody(_ json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let body = dict["articleBody"] as? String, !body.isEmpty { return body }
            for value in dict.values { if let found = findArticleBody(value) { return found } }
        } else if let array = json as? [Any] {
            for value in array { if let found = findArticleBody(value) { return found } }
        }
        return nil
    }

    /// 最长的 `<article>`。里面还常夹着作者卡片、标签、版权声明,所以优先取它
    /// 里面的段落,段落不够才用整块文字。
    static func longestArticle(_ html: String) -> String? {
        let cleaned = stripNoise(html)
        let blocks = captures("(?is)<article[^>]*>(.*?)</article>", in: cleaned)
        guard let longest = blocks.max(by: {
            NewsText.plainText(fromHTML: $0).count < NewsText.plainText(fromHTML: $1).count
        }) else { return nil }
        if let inner = paragraphs(longest), inner.count >= minimumLength { return inner }
        return NewsText.plainText(fromHTML: longest)
    }

    static func paragraphs(_ html: String) -> String? {
        let cleaned = stripNoise(html)
        let texts = captures("(?is)<p[^>]*>(.*?)</p>", in: cleaned)
            .map { NewsText.plainText(fromHTML: $0) }
            // 很短的段落多半是按钮、署名、版权行,不算正文。
            .filter { $0.count >= 12 }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }

    static func metaDescription(_ html: String) -> String? {
        for name in ["og:description", "description", "twitter:description"] {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let patterns = [
                "(?is)<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"']",
                "(?is)<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']",
            ]
            for pattern in patterns {
                if let value = captures(pattern, in: html).first {
                    let text = NewsText.plainText(fromHTML: value)
                    if !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// 导航、页眉页脚、侧栏、表单整块去掉,剩下的 <p> 才像正文。
    private static func stripNoise(_ html: String) -> String {
        html.replacingOccurrences(
            of: "(?is)<(script|style|noscript|nav|header|footer|aside|form|svg)[^>]*>.*?</\\1>",
            with: " ", options: .regularExpression)
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// 网页字节 → 字符串:先认 HTTP 头/`<meta charset>` 里声明的编码,认不出按
    /// UTF-8,再不行按 GB18030(国内老站常见)。
    public static func decode(_ data: Data, contentType: String?) -> String? {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        let declared = [contentType?.lowercased() ?? "", head].joined(separator: " ")
        if declared.contains("gb2312") || declared.contains("gbk") || declared.contains("gb18030") {
            let gb = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    /// r.jina.ai 这类阅读服务返回的是 Markdown(带一段 "Title:/URL Source:" 头):
    /// 去掉头部、图片、链接语法,只留文字。
    public static func cleanReaderMarkdown(_ markdown: String) -> String {
        var text = markdown
        if let range = text.range(of: "Markdown Content:") {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^[=\\-*_]{3,}\\s*$", with: "", options: .regularExpression)
        return cap(NewsText.collapse(text, keepNewlines: true))
    }
}
