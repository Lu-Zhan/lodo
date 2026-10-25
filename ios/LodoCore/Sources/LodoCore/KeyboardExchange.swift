import Foundation

/// 主 app 与 lodo 键盘扩展之间的约定。扩展**只读快照、只写收件箱**,不碰数据库。
///
/// - 快照 `keyboard-snapshot.json`:主 app 回前台/进后台时写,给键盘的 ✨ 检索记忆用。
///   **只有记忆,不放任务**(键盘改不了已有任务,用不上);**隐私口径同 Spotlight**:资产、健康、
///   体检报告、体重秤报告一律不进(键盘跑在别的 app 里,快照不该带出 app 外面不能出现的东西)。
/// - 收件箱:任务写 `Keyboard/Tasks/<uuid>.json`(一个 `ParsedTask`),记忆写分享扩展同一个
///   `Memory/Inbox/<uuid>/meta.json`。主 app 消费完只删处理过的文件,目录留着。
/// - 设置:主 app 把 AI 服务商/模型/语言等镜像进 App Group 的 UserDefaults,扩展启动时
///   拷进自己的 standard——`AppSettings` 读的是 standard,这样 LodoCore 一行不用改。
public enum KeyboardExchange {
    public static let groupID = "group.com.lodo.app"
    public static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    public static var snapshotURL: URL? { root?.appending(path: "keyboard-snapshot.json") }
    public static var shared: UserDefaults? { UserDefaults(suiteName: groupID) }
    public static var taskInbox: URL? { directory("Keyboard/Tasks") }
    public static var memoryInbox: URL? { directory("Memory/Inbox") }

    private static func directory(_ path: String) -> URL? {
        guard let url = root?.appending(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 快照

    public struct Memory: Codable, Equatable {
        public let uuid: String
        public let title: String
        public let summary: String
        public let tags: [String]
        public let excerpt: String
        public let createdAt: Date
        public init(uuid: String, title: String, summary: String, tags: [String], excerpt: String, createdAt: Date) {
            self.uuid = uuid; self.title = title; self.summary = summary; self.tags = tags
            self.excerpt = excerpt; self.createdAt = createdAt
        }
    }

    public struct Snapshot: Codable, Equatable {
        public var memories: [Memory]
        public init(memories: [Memory] = []) { self.memories = memories }
    }

    /// 快照里最多放这么多条记忆(按新近)。
    public static let memoryLimit = 500

    /// 这条记忆能不能进键盘快照。
    public static func isShareable(_ item: MemoryItem) -> Bool {
        !item.isAsset && !item.isHealth && !item.isCheckup && !item.isWeightReport
    }

    public static func loadSnapshot() -> Snapshot {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snapshot
    }

    public static func write(_ snapshot: Snapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - 收件箱

    @discardableResult
    public static func queueTask(_ task: ParsedTask) throws -> URL {
        guard let dir = taskInbox else { throw CocoaError(.fileNoSuchFile) }
        let url = dir.appending(path: "\(UUID().uuidString).json")
        try JSONEncoder().encode(task).write(to: url, options: .atomic)
        return url
    }

    /// `automatic` = AI 顺带记下的(收件箱 type "auto",打「AI记录」标签,不再整理一遍)。
    @discardableResult
    public static func queueMemory(text: String, title: String? = nil, automatic: Bool = false) throws -> URL {
        guard let inbox = memoryInbox else { throw CocoaError(.fileNoSuchFile) }
        let dir = inbox.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = ["type": automatic && title != nil ? "auto" : "text", "text": text]
        if let title { meta["title"] = title }
        try JSONEncoder().encode(meta).write(to: dir.appending(path: "meta.json"), options: .atomic)
        return dir
    }

    /// 撤销:主 app 还没消费就删掉;已经入库了返回 false(那时只能去 lodo 里删)。
    @discardableResult
    public static func unqueue(_ url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// 收件箱里还没被主 app 消费的任务。
    public static func pendingTasks() -> [(url: URL, task: ParsedTask)] {
        guard let dir = taskInbox,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let task = try? JSONDecoder().decode(ParsedTask.self, from: data) else { return nil }
            return (url, task)
        }
    }

    // MARK: - 强调色

    /// 主 app 写的强调色快照(`WidgetBridge.writeTheme`,`widget-theme.json`),键盘按它上色。
    /// fill/onFill 是后加的,老快照里没有时退回 accent / 白字。
    public struct Theme: Decodable, Equatable {
        public let accentLight: UInt32
        public let accentDark: UInt32
        public let fillLight: UInt32?
        public let fillDark: UInt32?
        public let onFillLight: UInt32?
        public let onFillDark: UInt32?
    }

    public static func loadTheme() -> Theme? {
        guard let url = root?.appending(path: "widget-theme.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Theme.self, from: data)
    }

    /// 键盘的「按键震动」开关(主 app 设置里改,默认开)。
    public static let hapticsKey = "keyboardHaptics"

    // MARK: - 设置镜像

    /// 键盘里 AI 键要用到的设置。思考强度不镜像:键盘里固定不思考(打字间隙等不起推理)。
    public static let mirroredKeys: [String] = [
        AppSettings.aiProviderKey, AppSettings.aiModelKey, AppSettings.aiCustomEndpointKey,
        AppSettings.useBuiltInKeyKey, AppSettings.agentPersonaStyleKey, AppSettings.agentPersonaCustomKey,
        AppSettings.languageKey,
    ]

    /// 键盘的模糊音开关(`FuzzyOptions.rawValue`),在主 app 设置里改,扩展读。
    public static let fuzzyKey = "keyboardFuzzy"

    public static func mirror(from source: UserDefaults, to target: UserDefaults) {
        for key in mirroredKeys {
            if let value = source.object(forKey: key) { target.set(value, forKey: key) }
            else { target.removeObject(forKey: key) }
        }
        for key in source.dictionaryRepresentation().keys where key.hasPrefix("agentSkillEnabled.") {
            target.set(source.object(forKey: key), forKey: key)
        }
    }

    /// 扩展启动时调:把主 app 镜像过来的设置拷进自己的 standard,并关掉思考。
    public static func adoptMirroredSettings(into standard: UserDefaults = .standard) {
        if let shared { mirror(from: shared, to: standard) }
        standard.set("off", forKey: AppSettings.thinkingLevelKey)
    }

    // MARK: - 在快照上检索记忆

    public static func retrieve(_ question: String, in snapshot: Snapshot) -> [Memory] {
        MemorySearch.rank(question: question, items: snapshot.memories.enumerated().map { index, m in
            (index: index, text: "\(m.title) \(m.summary) \(m.tags.joined(separator: " ")) \(m.excerpt)",
             createdAt: m.createdAt)
        }).map { snapshot.memories[$0] }
    }

    /// ReAct `search_memory` 的观察结果,格式和手机/手表逐字一致。
    public static func observation(for query: String, in snapshot: Snapshot) -> String {
        let found = retrieve(query, in: snapshot)
        guard !found.isEmpty else { return "没有找到相关记忆内容" }
        return found.map { "「\($0.title)」\($0.excerpt) [id:\($0.uuid)]" }.joined(separator: "\n")
    }
}
