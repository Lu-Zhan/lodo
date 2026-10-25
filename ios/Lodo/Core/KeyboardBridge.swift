import Foundation
import SwiftData
import LodoCore

/// 主 app 这一侧的 lodo 键盘桥:收键盘写进来的任务、给键盘写记忆快照、镜像 AI 设置。
/// 约定见 `KeyboardExchange`。键盘写进 `Memory/Inbox` 的收藏和分享扩展共用收件箱,
/// 由 `MemoryPipeline.consumeInbox` 照常入库,这里不管。
@MainActor
enum KeyboardBridge {
    /// 回前台 / 进后台时调。
    static func refresh(context: ModelContext) {
        #if os(iOS)
        consumeTasks(context: context)
        writeSnapshot(context: context)
        if let shared = KeyboardExchange.shared {
            KeyboardExchange.mirror(from: .standard, to: shared)
        }
        #endif
    }

    /// 存成功了才删文件(目录留着,键盘随时还会往里写);存失败就留着文件下次再试。
    /// **任务 uuid 就是收件箱文件名**(键盘写文件时用 UUID 命名):重试时查库里有没有这个 uuid
    /// 就知道入没入库,去重以数据库为准,不靠另记一份凭据(UserDefaults 是异步落盘的,靠不住)。
    static func consumeTasks(context: ModelContext) {
        let pending = KeyboardExchange.pendingTasks()
        guard !pending.isEmpty else { return }
        var created = false
        for (url, task) in pending {
            guard let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                try? FileManager.default.removeItem(at: url) // 不是键盘写的文件
                continue
            }
            let exists = ((try? context.fetchCount(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.uuid == uuid }))) ?? 0) > 0
            if !exists {
                do {
                    try TaskActions.createOrThrow(task, uuid: uuid, context: context)
                } catch {
                    continue // 文件留着,下次用同一个 uuid 再试
                }
                created = true
            }
            try? FileManager.default.removeItem(at: url)
        }
        if created {
            WidgetBridge.sync(context: context)
            CalendarSync.sync(context: context)
        }
    }

    private static func writeSnapshot(context: ModelContext) {
        var descriptor = FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 2000
        let memories = ((try? context.fetch(descriptor)) ?? [])
            .filter(KeyboardExchange.isShareable)
            .prefix(KeyboardExchange.memoryLimit)
            .map { KeyboardExchange.Memory(
                uuid: $0.uuid.uuidString, title: $0.title, summary: $0.summary, tags: $0.tags,
                excerpt: MemorySearch.truncate($0.sourceText, limit: MemorySearch.maxExcerptChars),
                createdAt: $0.createdAt) }
        KeyboardExchange.write(.init(memories: Array(memories)))
    }
}
