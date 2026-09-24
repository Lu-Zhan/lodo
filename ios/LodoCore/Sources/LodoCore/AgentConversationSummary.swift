import Foundation

/// 单一持续对话的常驻摘要:最近 `recentWindow` 条消息逐条带进 prompt(见
/// `DeepSeekClient.historyBlock`),更早的压成一段文字常驻在 system prompt 里
/// (见 `DeepSeekClient.summaryBlock`)。对话永不结束,不压缩就等于说过的话
/// 滑出窗口后彻底失忆。
///
/// 落 Application Support 文件而不是 SwiftData:这是**可重算的派生数据**,
/// 丢了只要重压一遍(消息本身会随 CloudKit 同步下来)。反过来若做成 @Model,
/// 两台设备会各自压出一条记录,而 CloudKit 那套"每个属性有默认值、无 unique
/// 约束"的要求让它们没法靠主键去重,得额外写一套合并逻辑——为一份缓存不值当。
/// 写法整体照 `AgentPreferences`,区别是要带一条水位线,所以存 JSON 不是 md。
public enum AgentConversationSummary {
    /// 逐条带进 `historyBlock` 的条数。
    public static let recentWindow = 16
    /// 窗口之外积够这么多条才压一次;太小会频繁发请求,太大则摘要长期滞后。
    public static let compressBatch = 20

    private struct Stored: Codable {
        var summary: String
        var coveredUntil: Date
        var coveredCount: Int
        var updatedAt: Date
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "agent-conversation-summary.json")
    }

    private static var stored: Stored? {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(Stored.self, from: data),
              !value.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// 摘要正文;没压过或文件损坏返回 nil(prompt 里那一段因此整段不出现)。
    public static var content: String? { stored?.summary }

    /// 水位线:已经被压进摘要的最后一条消息的 createdAt。没有摘要时是
    /// `.distantPast`,这样"晚于水位线的消息"天然等于"全部消息"。
    public static var coveredUntil: Date { stored?.coveredUntil ?? .distantPast }

    /// 已压进摘要的消息条数,只用于展示(设置页)。
    public static var coveredCount: Int { stored?.coveredCount ?? 0 }

    public static func save(_ summary: String, coveredUntil: Date, coveredCount: Int) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        let value = Stored(summary: trimmed, coveredUntil: coveredUntil,
                           coveredCount: coveredCount, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
