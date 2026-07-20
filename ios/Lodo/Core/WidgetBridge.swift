import Foundation
import SwiftData
import WidgetKit
import LodoCore

/// App Group 共享容器:数据库与小组件快照都放这里,app 和小组件两侧共用。
enum AppGroup {
    static let id = "group.com.lodo.app"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var storeURL: URL? { containerURL?.appending(path: "lodo.store") }
    static var snapshotURL: URL? { containerURL?.appending(path: "widget-upcoming.json") }

    /// AI 收藏的原始文件目录(按需创建);Inbox 是 Share Extension 的收件箱,
    /// 扩展只往里落文件,主 app 回前台时消费。
    static var memoryDirURL: URL? { directory("Memory") }
    static var inboxDirURL: URL? { directory("Memory/Inbox") }

    private static func directory(_ path: String) -> URL? {
        guard let url = containerURL?.appending(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 老版本数据库在默认位置(Application Support/default.store),
    /// 迁到 App Group 前先整套拷过去,避免升级丢数据。
    static func migrateLegacyStoreIfNeeded(to newURL: URL) {
        let fm = FileManager.default
        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard !fm.fileExists(atPath: newURL.path),
              fm.fileExists(atPath: legacy.path) else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? fm.copyItem(at: URL(fileURLWithPath: legacy.path + suffix),
                             to: URL(fileURLWithPath: newURL.path + suffix))
        }
    }
}

/// 把即将到来的待办快照写进 App Group,并让小组件刷新。
/// 字段与 LodoWidget 的 UpcomingItem 保持一致。
enum WidgetBridge {
    private struct Item: Codable {
        let title: String
        let at: Date
    }

    /// 上次写入的快照,内容未变时不写盘、不 reload(去抖)。
    @MainActor
    private static var lastSnapshot: Data?

    @MainActor
    static func sync(context: ModelContext) {
        guard let url = AppGroup.snapshotURL else { return }
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" },
            sortBy: [SortDescriptor(\.nextRemindAt)])
        descriptor.fetchLimit = 6
        let items = ((try? context.fetch(descriptor)) ?? [])
            .map { Item(title: $0.title, at: $0.nextRemindAt) }
        guard let data = try? JSONEncoder().encode(items) else { return }
        if data == lastSnapshot { return }
        lastSnapshot = data
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
