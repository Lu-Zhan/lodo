import Foundation
import SwiftData
import LodoCore

@MainActor
enum KeyboardBridge {
    static func refresh(context: ModelContext) {
        consumeTasks(context: context)
        let memories = ((try? context.fetch(FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? [])
            .prefix(500)
            .map { KeyboardExchange.Memory(
                title: $0.title, summary: $0.summary, tags: $0.tags,
                excerpt: MemorySearch.truncate($0.sourceText, limit: MemorySearch.maxExcerptChars),
                createdAt: $0.createdAt) }
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" }))) ?? [])
            .map { KeyboardExchange.Task(uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        if let url = KeyboardExchange.snapshotURL,
           let data = try? JSONEncoder().encode(KeyboardExchange.Snapshot(
            memories: Array(memories), tasks: tasks)) {
            try? data.write(to: url, options: .atomic)
        }
        mirrorSettings()
    }

    /// 思考强度不镜像:键盘里固定不思考(打字间隙等不起推理模型)。
    private static func mirrorSettings() {
        guard let shared = KeyboardExchange.settings else { return }
        let source = UserDefaults.standard
        for key in [AppSettings.aiProviderKey, AppSettings.aiModelKey,
                    AppSettings.aiCustomEndpointKey, AppSettings.useBuiltInKeyKey,
                    AppSettings.agentPersonaStyleKey,
                    AppSettings.agentPersonaCustomKey, AppSettings.languageKey] {
            if let value = source.object(forKey: key) { shared.set(value, forKey: key) }
            else { shared.removeObject(forKey: key) }
        }
        for skill in AgentSkillID.allCases {
            let key = "agentSkillEnabled.\(skill.rawValue)"
            if let value = source.object(forKey: key) { shared.set(value, forKey: key) }
        }
    }

    private static func consumeTasks(context: ModelContext) {
        guard let inbox = KeyboardExchange.taskInbox,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let task = try? JSONDecoder().decode(ParsedTask.self, from: data) else { continue }
            TaskActions.create(task, context: context)
            try? FileManager.default.removeItem(at: url)
        }
        WidgetBridge.sync(context: context)
        CalendarSync.sync(context: context)
    }
}
