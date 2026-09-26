import Foundation

/// 主 app 与键盘扩展共享的轻量协议。扩展只读快照、只写收件箱。
public enum KeyboardExchange {
    public static let groupID = "group.com.lodo.app"
    public static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    public static var snapshotURL: URL? { root?.appending(path: "keyboard-snapshot.json") }
    public static var settings: UserDefaults? { UserDefaults(suiteName: groupID) }
    public static var taskInbox: URL? { directory("Keyboard/Tasks") }
    public static var memoryInbox: URL? { directory("Memory/Inbox") }
    private static func directory(_ path: String) -> URL? {
        guard let url = root?.appending(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public struct Memory: Codable {
        public let title: String
        public let summary: String
        public let tags: [String]
        public let excerpt: String
        public let createdAt: Date
        public init(title: String, summary: String, tags: [String], excerpt: String, createdAt: Date) {
            self.title = title; self.summary = summary; self.tags = tags
            self.excerpt = excerpt; self.createdAt = createdAt
        }
    }
    public struct Task: Codable {
        public let uuid: String
        public let task: ParsedTask
        public init(uuid: String, task: ParsedTask) { self.uuid = uuid; self.task = task }
    }
    public struct Snapshot: Codable {
        public let memories: [Memory]
        public let tasks: [Task]
        public init(memories: [Memory], tasks: [Task]) {
            self.memories = memories; self.tasks = tasks
        }
    }

    @discardableResult
    public static func queueTask(_ task: ParsedTask) throws -> URL {
        guard let dir = taskInbox else { throw CocoaError(.fileNoSuchFile) }
        let url = dir.appending(path: "\(UUID().uuidString).json")
        try JSONEncoder().encode(task).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func queueMemory(text: String, title: String? = nil, automatic: Bool = false) throws -> URL {
        guard let inbox = memoryInbox else { throw CocoaError(.fileNoSuchFile) }
        let dir = inbox.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = ["type": automatic ? "auto" : "text", "text": text]
        if let title { meta["title"] = title }
        try JSONEncoder().encode(meta).write(to: dir.appending(path: "meta.json"), options: .atomic)
        return dir
    }
}
