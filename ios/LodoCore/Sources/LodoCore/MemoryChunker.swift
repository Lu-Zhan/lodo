import Foundation

/// 记忆正文分片:纯逻辑,不依赖 SwiftData/网络,可单测。
/// 短文本(多数手动记的内容)整条当一个 chunk;长文本按字符数切,带重叠避免
/// 关键信息正好落在切点两侧都不完整。
public enum MemoryChunker {
    public static let targetChars = 700
    public static let overlapChars = 100

    /// 空文本返回空数组(调用方不必再判断)。
    public static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > targetChars else { return [trimmed] }

        var chunks: [String] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex {
            let end = trimmed.index(start, offsetBy: targetChars, limitedBy: trimmed.endIndex)
                ?? trimmed.endIndex
            chunks.append(String(trimmed[start..<end]))
            if end == trimmed.endIndex { break }
            // 下一片往回退 overlapChars,与上一片有重叠;至少前进 1 个字符防止死循环。
            let step = max(targetChars - overlapChars, 1)
            start = trimmed.index(start, offsetBy: step, limitedBy: trimmed.endIndex)
                ?? trimmed.endIndex
        }
        return chunks
    }
}
