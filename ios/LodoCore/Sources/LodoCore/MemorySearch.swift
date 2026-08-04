import Foundation

/// 记忆功能的纯逻辑部分:文本截断、扩展名 → 类型映射、"问 AI"前的关键词粗排。
/// 放 LodoCore(而不是 app 层)是为了能在 swift test 里独立测试。
public enum MemorySearch {

    /// 提取文本存库与喂 AI 的统一截断上限(字符数)。
    public static let maxSourceChars = 8000
    /// "问 AI"时每条条目带入 prompt 的原文摘录上限。
    public static let maxExcerptChars = 400
    /// "问 AI"时最多带入 prompt 的条目数。
    public static let maxAskItems = 20

    /// 按字符数截断(Character 边界,emoji 不劈半);超长时结尾加省略号。
    public static func truncate(_ text: String, limit: Int = maxSourceChars) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// 文件扩展名 → 记忆类型;认不出的一律归 file(保留原文件不解析)。
    public static func kind(forExtension ext: String) -> MemoryKind {
        switch ext.lowercased() {
        case "pdf":
            return .pdf
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tiff":
            return .image
        case "txt", "md", "markdown", "csv", "json", "log":
            return .text
        default:
            return .file
        }
    }

    /// "问 AI"前的本地粗排:按问题分词与条目文字的重合度计分取前 limit 条,
    /// 不足时按创建时间倒序补齐(保证 AI 总有语料可看)。
    /// 入参用元组而不是 MemoryItem,保持纯逻辑可测。
    public static func rank(
        question: String,
        items: [(index: Int, text: String, createdAt: Date)],
        limit: Int = maxAskItems
    ) -> [Int] {
        let terms = tokens(of: question)
        let scored = items.map { item -> (index: Int, score: Int, createdAt: Date) in
            let haystack = item.text.lowercased()
            let score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return (item.index, score, item.createdAt)
        }
        let matched = scored.filter { $0.score > 0 }
            .sorted { ($0.score, $0.createdAt) > ($1.score, $1.createdAt) }
        var result = matched.map(\.index)
        if result.count < limit {
            let rest = scored.filter { $0.score == 0 }
                .sorted { $0.createdAt > $1.createdAt }
                .map(\.index)
            result.append(contentsOf: rest)
        }
        return Array(result.prefix(limit))
    }

    /// "问 AI"时最多带入待办历史匹配结果的条数。
    public static let maxHistoryItems = 10

    /// 待办历史(已完成的 TaskItem)的关键词匹配:只返回真正命中的,不像 rank(:)
    /// 那样在命中不足时拿近期条目填充凑数——"上次做过 X"答不出来时不该被
    /// "最近随便一条待办"冒充答案,宁可返回空。
    public static func matchTaskHistory(
        question: String,
        items: [(index: Int, title: String)],
        limit: Int = maxHistoryItems
    ) -> [Int] {
        let terms = tokens(of: question)
        guard !terms.isEmpty else { return [] }
        let scored = items.map { item -> (index: Int, score: Int) in
            let haystack = item.title.lowercased()
            let score = terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            return (item.index, score)
        }
        let matched = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        return Array(matched.prefix(limit).map(\.index))
    }

    /// 问题 → 检索词:按非字母数字切分取英文单词,中文再按双字滑窗补充
    /// (无分词库下对中文最实用的近似)。
    static func tokens(of question: String) -> [String] {
        let lowered = question.lowercased()
        var terms = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let cjk = lowered.unicodeScalars.filter { $0.properties.isIdeographic }
        let chars = cjk.map(Character.init)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                terms.append(String(chars[i]) + String(chars[i + 1]))
            }
        } else if chars.count == 1 {
            terms.append(String(chars[0]))
        }
        return Array(Set(terms))
    }
}
