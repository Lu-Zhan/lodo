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
    /// force 绕过节流(实际耗时回答紧跟完成时的常规 learn,不该被节流吞掉)。
    static func learn(title: String, durationMinutes: Int, force: Bool = false) {
        guard durationMinutes > 0, DeepSeekClient.isConfigured else { return }
        guard force || Date().timeIntervalSince(lastLearned) >= throttleSeconds else { return }
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

    // MARK: - 实际耗时采样(智能 + 随机,时间稳定后不再问)

    private struct Sample: Codable {
        var actuals: [Int] = []
        var lastAsked: Date = .distantPast
        var stable = false
    }

    private static var samplesURL: URL {
        URL.applicationSupportDirectory.appending(path: "duration-samples.json")
    }
    private static let askDayKey = "durationAskDay"

    private static func loadSamples() -> [String: Sample] {
        guard let data = try? Data(contentsOf: samplesURL),
              let samples = try? JSONDecoder().decode([String: Sample].self, from: data) else {
            return [:]
        }
        return samples
    }

    private static func saveSamples(_ samples: [String: Sample]) {
        try? FileManager.default.createDirectory(
            at: samplesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: samplesURL, options: .atomic)
        }
    }

    /// 这次完成要不要问实际耗时:计划>0、该事项未稳定、今天没问过任何事项、
    /// 该事项 7 天内没问过,满足后再掷 50% 随机。返回 true 即视为"已问"
    /// (跳过也算),避免连环追问。
    static func shouldAskActual(title: String, planned: Int) -> Bool {
        guard planned > 0 else { return false }
        var samples = loadSamples()
        var sample = samples[title] ?? Sample()
        guard !sample.stable else { return false }
        let defaults = UserDefaults.standard
        if let lastDay = defaults.object(forKey: askDayKey) as? Date,
           Calendar.current.isDateInToday(lastDay) { return false }
        guard Date().timeIntervalSince(sample.lastAsked) > 7 * 86400 else { return false }
        guard Bool.random() else { return false }
        sample.lastAsked = Date()
        samples[title] = sample
        saveSamples(samples)
        defaults.set(Date(), forKey: askDayKey)
        return true
    }

    /// 记录用户回答的实际耗时:入样本 + 喂记忆;
    /// 最近 3 次实际值都与计划偏差 ≤20% 则标记稳定,以后不再问。
    static func recordActual(title: String, planned: Int, minutes: Int) {
        var samples = loadSamples()
        var sample = samples[title] ?? Sample()
        sample.actuals = Array((sample.actuals + [minutes]).suffix(3))
        if sample.actuals.count >= 3, planned > 0,
           sample.actuals.allSatisfy({ abs($0 - planned) <= max(5, planned / 5) }) {
            sample.stable = true
        }
        samples[title] = sample
        saveSamples(samples)
        learn(title: title, durationMinutes: minutes, force: true)
    }
}
