#if os(iOS)
import AppIntents
import Foundation
import SwiftData
import LodoCore

/// Intent 共用的数据与配置入口。
@MainActor
enum LodoIntentSupport {
    /// Siri 添加失败时的交接文本:app 下次到前台自动弹出 agent 并预填。
    static let pendingAgentTextKey = "pendingAgentText"
    static let agentHandoff = Notification.Name("LodoAgentHandoff")

    static var context: ModelContext { AppDatabase.container.mainContext }

    /// 后台拉起路径下补一次通知配置,保证 rebuild/小组件同步可用(幂等)。
    static func ensureConfigured() {
        NotificationManager.shared.configure(container: AppDatabase.container)
    }

    static func pendingTasks() -> [TaskItem] {
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" },
            sortBy: [SortDescriptor(\.nextRemindAt)])
        descriptor.fetchLimit = 50
        return (try? context.fetch(descriptor)) ?? []
    }

    static func todayPending() -> [TaskItem] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        return pendingTasks().filter { $0.nextRemindAt < endOfToday }
    }

    /// 把一句话交给 app 内 agent(设置交接文本 + 广播,双通道保证送达)。
    static func handOffToAgent(_ text: String) {
        UserDefaults.standard.set(text, forKey: pendingAgentTextKey)
        NotificationCenter.default.post(name: agentHandoff, object: nil,
                                        userInfo: ["text": text])
    }
}

// MARK: - 事项实体(Siri 消歧/快捷指令选择器用)

struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "待办事项"
    static let defaultQuery = TaskQuery()

    let id: UUID
    let title: String
    let caption: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(caption)")
    }

    @MainActor
    init(task: TaskItem) {
        id = task.uuid
        title = task.title
        caption = task.caption
    }
}

struct TaskQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        LodoIntentSupport.pendingTasks()
            .filter { identifiers.contains($0.uuid) }
            .map(TaskEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        LodoIntentSupport.pendingTasks()
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
            .map(TaskEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        LodoIntentSupport.pendingTasks().map(TaskEntity.init)
    }
}

// MARK: - 添加事项

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "添加事项"
    static let description = IntentDescription("用一句话添加待办事项,AI 解析时间和时长。")

    @Parameter(title: "内容", requestValueDialog: "要提醒你什么?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        LodoIntentSupport.ensureConfigured()
        do {
            var parsed = try await DeepSeekClient.parse(text)
            if parsed.durationMinutes == 0, let memory = DurationMemory.content,
               let minutes = try? await DeepSeekClient.suggestDuration(
                   text: text, title: parsed.title, memory: memory),
               minutes > 0 {
                parsed.durationMinutes = minutes
            }
            let task = TaskItem(
                title: parsed.title, remindAt: parsed.remindAt,
                durationMinutes: parsed.durationMinutes, allDay: parsed.allDay,
                repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
                repeatTimes: parsed.repeatTimes)
            let context = LodoIntentSupport.context
            context.insert(task)
            try? context.save()
            NotificationManager.shared.rebuild(for: task)
            DurationMemory.learn(title: parsed.title,
                                 durationMinutes: parsed.durationMinutes)
            return .result(dialog: IntentDialog(stringLiteral:
                "已添加:\(task.title),\(TaskItem.format(task.nextRemindAt))"))
        } catch {
            // 解析不了(缺时间/无 key/断网):交接给 app 内 agent,下次打开自动带出
            LodoIntentSupport.handOffToAgent(text)
            return .result(dialog: IntentDialog(stringLiteral:
                "暂时没法直接添加。打开 lodo,AI 助手会带着这句话等你补充。"))
        }
    }
}

// MARK: - 今天有什么安排

struct TodayTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "今天有什么安排"
    static let description = IntentDescription("查看今天开始或到期的待办事项。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tasks = LodoIntentSupport.todayPending()
        guard !tasks.isEmpty else {
            return .result(dialog: "今天没有待办事项 🎉")
        }
        let names = tasks.prefix(5).map(\.title).joined(separator: "、")
        let suffix = tasks.count > 5 ? "等 \(tasks.count) 件事" : "共 \(tasks.count) 件事"
        return .result(dialog: IntentDialog(stringLiteral: "今天\(suffix):\(names)"))
    }
}

// MARK: - 完成事项

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "完成事项"
    static let description = IntentDescription("把一个待办事项标记为完成。")

    @Parameter(title: "事项", requestValueDialog: "完成哪个事项?")
    var task: TaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        LodoIntentSupport.ensureConfigured()
        guard let item = LodoIntentSupport.pendingTasks()
            .first(where: { $0.uuid == task.id }) else {
            return .result(dialog: "没有找到这个事项,它可能已经完成了。")
        }
        NotificationManager.shared.complete(item, context: LodoIntentSupport.context)
        return .result(dialog: IntentDialog(stringLiteral: "已完成:\(item.title)"))
    }
}

// MARK: - 打开助手

struct OpenAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 lodo 助手"
    static let description = IntentDescription("打开 lodo 的全局 AI 助手。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LodoIntentSupport.handOffToAgent("")
        return .result()
    }
}

// MARK: - Siri 短语

struct LodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["在\(.applicationName)里添加事项",
                              "用\(.applicationName)添加待办"],
                    shortTitle: "添加事项",
                    systemImageName: "plus.circle")
        AppShortcut(intent: TodayTasksIntent(),
                    phrases: ["\(.applicationName)今天有什么安排",
                              "问\(.applicationName)今天的待办"],
                    shortTitle: "今天待办",
                    systemImageName: "calendar")
        AppShortcut(intent: CompleteTaskIntent(),
                    phrases: ["在\(.applicationName)里完成事项"],
                    shortTitle: "完成事项",
                    systemImageName: "checkmark.circle")
        AppShortcut(intent: OpenAgentIntent(),
                    phrases: ["打开\(.applicationName)助手"],
                    shortTitle: "AI 助手",
                    systemImageName: "sparkles")
    }
}
#endif
