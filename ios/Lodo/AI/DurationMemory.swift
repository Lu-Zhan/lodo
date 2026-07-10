import Foundation

/// AI 时长记忆:一个类 skill 的 markdown 文件,记录"事项类型 → 典型时长"。
///
/// 事项保存/完成(且有时长)时交给 DeepSeek 归纳合并写回;
/// 新建解析出的事项没有时长时,再用它做一次小请求建议时长。
/// 全程尽力而为:无 API key、断网、解析失败都静默跳过,不影响主流程。
enum DurationMemory {
    /// 距上次成功归纳 < 60 秒则跳过,避免连续编辑刷请求。
    private static let throttleSeconds: TimeInterval = 60
    private static var lastLearned: Date = .distantPast

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "duration-memory.md")
    }

    /// 当前记忆文件内容;不存在或为空返回 nil。
    static var content: String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// 手动保存编辑后的记忆内容(设置页编辑用);空内容等同重置。
    static func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    /// 清空记忆。
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 用一条新样本(标题 + 时长)让 AI 归纳更新记忆文件,fire-and-forget。
    static func learn(title: String, durationMinutes: Int) {
        guard durationMinutes > 0, KeychainHelper.apiKey != nil else { return }
        guard Date().timeIntervalSince(lastLearned) >= throttleSeconds else { return }
        lastLearned = Date()
        let current = content
        Task.detached(priority: .background) {
            guard let updated = try? await DeepSeekClient.updateMemory(
                current: current, title: title, durationMinutes: durationMinutes),
                !updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(updated.utf8).write(to: fileURL, options: .atomic)
        }
    }
}
