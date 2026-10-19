import Foundation

/// 新闻朗读要念的文字(纯逻辑,单测 `NewsSpeechTests`)。真正发声在 app 层 `NewsSpeaker`
/// (系统 AVSpeechSynthesizer,本机合成,不联网)。
///
/// 拼法:标题念一遍、停顿,再念正文;图片跳过,列表项逐条念;太长的正文按句子切成几段
/// 依次排进合成器(一段太长时系统会卡一下才开口,而且中途停不干净)。
public enum NewsSpeech {
    /// 每段最多这么多字。
    public static let chunkLimit = 400

    /// 一篇文章:标题 + 正文(抓到的结构化正文优先,没有就用 feed 摘要)。
    public static func article(title: String, blocks: [ArticleBlock], fallback: String) -> String {
        var parts = [title]
        let body = blocks.compactMap { block -> String? in
            switch block {
            case .heading(let text), .paragraph(let text), .quote(let text), .listItem(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != title else { return nil }
                return trimmed
            case .image:
                return nil
            }
        }
        if body.isEmpty {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        } else {
            parts.append(contentsOf: body)
        }
        return parts.joined(separator: "\n")
    }

    /// 单篇 AI 总结:标题 + 一句话总结 + 要点。
    public static func summary(title: String, summary: NewsArticleSummary) -> String {
        ([title, summary.summary] + summary.points)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 列表里左滑「朗读」:标题 + AI 总结(有的话)或 feed 摘要。
    public static func brief(title: String, aiSummary: NewsArticleSummary?, feedSummary: String) -> String {
        if let aiSummary { return summary(title: title, summary: aiSummary) }
        return article(title: title, blocks: [], fallback: feedSummary)
    }

    /// 「今日」那份总结:概览 + 每条「1. 标题。说明」。
    public static func digest(_ digest: NewsDigest) -> String {
        var parts: [String] = []
        let overview = digest.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { parts.append(overview) }
        for (index, item) in digest.items.enumerated() {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("\(index + 1). \(title)\(endsWithPunctuation(title) ? "" : "。")\(detail)")
        }
        return parts.joined(separator: "\n")
    }

    /// 切成几段:先按换行,太长的段再按句末标点切,实在没有标点就硬切。
    public static func chunks(_ text: String, limit: Int = chunkLimit) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var current = ""
            for sentence in sentences(trimmed) {
                if current.count + sentence.count > limit, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                if sentence.count > limit {
                    var rest = Substring(sentence)
                    while rest.count > limit {
                        result.append(String(rest.prefix(limit)))
                        rest = rest.dropFirst(limit)
                    }
                    current = String(rest)
                } else {
                    current += sentence
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    private static let sentenceEnds: Set<Character> = [
        "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF1B}", "!", "?", ";", ".",
    ]

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if sentenceEnds.contains(character) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func endsWithPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return sentenceEnds.contains(last) || last == ":" || last == "\u{FF1A}"
    }
}
