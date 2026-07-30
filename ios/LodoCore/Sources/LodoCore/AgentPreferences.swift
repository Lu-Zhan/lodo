import Foundation

/// AI 在对话里自动维护的「用户偏好」文件:一行一条"以后都这样办"的做事习惯
/// (如"开会默认留 60 分钟""说话简短点"),每轮 `command` 都拼进 system prompt。
///
/// 和另外两种长期记忆分工:显式收藏的资料内容归记忆库(`MemoryItem`),
/// "事项类型 → 典型时长"归 `DurationMemory`,"希望 AI 以后怎么做事"归这里。
///
/// 放 LodoCore 而不是 app 层:`DeepSeekClient.command` 要直接读它拼 prompt
/// (和 `AgentSkillStore` 同一个道理)。写入是静默的——模型返回
/// `remember_preference` 就落盘,不弹确认;用户在设置里可以查看/编辑/重置。
public enum AgentPreferences {
    /// 超过这个条数就让 AI 归纳合并一次(而不是丢掉最老的——静默丢弃用户
    /// 说过的偏好比合并更糟)。
    static let maxLines = 40

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "agent-preferences.md")
    }

    /// 当前偏好文件内容;不存在或为空返回 nil(prompt 里那一段因此整段不出现)。
    public static var content: String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// 手动保存编辑后的内容(设置页用);空内容等同重置。
    public static func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        write(text)
    }

    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 追加一条偏好。已经记过的(与某条互相包含)直接跳过,不重复记——
    /// 模型未必每次都记得自己写过什么,去重放在客户端更稳。
    /// 追加后条数超上限时触发一次后台归纳合并。
    public static func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var lines = existingLines
        let normalized = normalize(trimmed)
        guard !lines.contains(where: {
            let existing = normalize($0)
            return existing.localizedStandardContains(normalized)
                || normalized.localizedStandardContains(existing)
        }) else { return }
        lines.append("- \(trimmed)")
        write(lines.joined(separator: "\n") + "\n")
        consolidateIfNeeded()
    }

    /// 已有的条目行(去掉标题行和空行);文件不存在时为空数组。
    static var existingLines: [String] {
        (content ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 去重比对用:剥掉列表符号和首尾空白,只比正文。
    private static func normalize(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "· "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func write(_ text: String) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    /// 条数超上限时让 AI 重写整份文件,fire-and-forget;无 key/断网/解析失败
    /// 都静默跳过、保持原样(与 `DurationMemory.learn` 一样不影响主流程)。
    static func consolidateIfNeeded() {
        guard existingLines.count > maxLines, DeepSeekClient.isConfigured,
              let current = content else { return }
        Task.detached(priority: .background) {
            guard let updated = try? await DeepSeekClient.consolidatePreferences(current: current),
                  !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            write(updated)
        }
    }
}
