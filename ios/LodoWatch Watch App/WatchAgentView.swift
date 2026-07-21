import SwiftUI
import SwiftData
import LodoCore

/// Watch 语音助手:一句话新增/修改/完成/删除待办(可批量)。
/// 不区分单条/批量,统一展示"即将执行"确认清单,一键确认后才真正落库
/// (用户明确要求不需要手动编辑表单,一键确认是保留的唯一安全阀)。
/// TextField 在 watchOS 上点击后系统自带听写输入,不需要自己接语音识别 API。
struct WatchAgentView: View {
    let pending: [TaskItem]
    let context: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var pendingActions: [AIAction] = []
    @State private var confirmLines: [String]?
    @State private var clarify: (question: String, options: [String])?
    @State private var clarifyBase = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("说点什么…", text: $text)
                    .onSubmit { parse() }

                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = errorText {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let clarify {
                    clarifySection(clarify)
                }
                if let confirmLines {
                    confirmSection(confirmLines)
                }
                if confirmLines == nil && clarify == nil {
                    Button {
                        parse()
                    } label: {
                        Label("解析", systemImage: "sparkles")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("AI 助手")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", role: .cancel) { dismiss() }
            }
        }
    }

    private func clarifySection(_ clarify: (question: String, options: [String])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(clarify.question, systemImage: "questionmark.circle").font(.footnote)
            ForEach(clarify.options, id: \.self) { option in
                Button(option) { resolveClarify(with: option) }
                    .font(.footnote)
            }
        }
    }

    private func confirmSection(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: icon(for: line)).font(.footnote)
            }
            Button {
                performPendingActions()
            } label: {
                Label("确认执行", systemImage: "checkmark")
            }
            .tint(.green)
            Button("取消", role: .cancel) {
                confirmLines = nil
                pendingActions = []
            }
        }
    }

    private func icon(for line: String) -> String {
        if line.hasPrefix("新建") { return "plus.circle" }
        if line.hasPrefix("修改") { return "pencil.circle" }
        if line.hasPrefix("完成") { return "checkmark.circle" }
        if line.hasPrefix("删除") { return "trash.circle" }
        return "circle"
    }

    // MARK: - 提交

    private func resolveClarify(with option: String) {
        let base = clarifyBase.isEmpty ? text : clarifyBase
        clarify = nil
        parse(override: "\(base)\n补充:\(option)")
    }

    private func parse(override: String? = nil) {
        let trimmed = (override ?? text).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        errorText = nil
        confirmLines = nil
        let taskContext = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        Task {
            defer { busy = false }
            do {
                switch try await DeepSeekClient.command(trimmed, tasks: taskContext) {
                case .clarify(let question, let options):
                    clarifyBase = trimmed
                    confirmLines = nil
                    clarify = (question: question, options: options)
                case .actions(let actions):
                    clarify = nil
                    pendingActions = actions
                    confirmLines = actions.map(describe)
                case .toolCall:
                    // 死代码安全阀:Watch 调 command 不传 memoryEnabled(恒 false),
                    // prompt 里根本没提过"先查记忆"这个选项,模型不会返回这个 case。
                    errorText = "暂不支持的操作类型"
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func describe(_ action: AIAction) -> String {
        switch action {
        case .create(let parsed):
            var caption = TaskItem.format(parsed.remindAt)
            if parsed.durationMinutes > 0 { caption += " · \(parsed.durationMinutes) 分钟" }
            return "新建:\(parsed.title)(\(caption))"
        case .update(_, let parsed):
            return "修改:\(parsed.title)(\(TaskItem.format(parsed.remindAt)))"
        case .complete(let uuid):
            return "完成:\(title(of: uuid) ?? "未知事项")"
        case .delete(let uuid):
            return "删除:\(title(of: uuid) ?? "未知事项")"
        case .memorize, .askMemory, .answer:
            // 死代码安全阀:Watch 调 command 不传 memoryEnabled/webSearchEnabled
            // (无 MemoryItem 数据层、也没有联网搜索),这几支不会被模型返回,
            // 仅为满足穷尽 switch。
            return ""
        }
    }

    private func title(of uuid: String) -> String? {
        pending.first { $0.uuid.uuidString == uuid }?.title
    }

    /// 等待确认期间,目标事项可能已被通知按钮改动或完成/删除;
    /// 找不到时静默跳过该条(Watch 屏幕小,不额外展示警示文案)。
    private func performPendingActions() {
        for action in pendingActions {
            switch action {
            case .create(let parsed):
                let task = TaskItem(
                    title: parsed.title, remindAt: parsed.remindAt,
                    durationMinutes: parsed.durationMinutes, allDay: parsed.allDay,
                    repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
                    repeatTimes: parsed.repeatTimes)
                context.insert(task)
                WatchNotificationManager.shared.rebuild(for: task)
            case .update(let uuid, let parsed):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                task.title = parsed.title
                task.remindAt = parsed.remindAt
                task.durationMinutes = parsed.durationMinutes
                task.allDay = parsed.allDay
                task.repeatTypeRaw = parsed.repeatType.rawValue
                task.repeatDays = parsed.repeatDays
                task.repeatTimes = parsed.repeatTimes
                task.phaseRaw = TaskPhase.start.rawValue
                task.nextRemindAt = parsed.remindAt
                WatchNotificationManager.shared.rebuild(for: task)
            case .complete(let uuid):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                WatchNotificationManager.shared.complete(task, context: context)
            case .delete(let uuid):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                WatchNotificationManager.shared.cancelChain(for: task.uuid)
                context.delete(task)
            case .memorize, .askMemory, .answer:
                // 死代码安全阀:Watch 未开 memoryEnabled/webSearchEnabled,不会实际出现。
                continue
            }
        }
        try? context.save()
        pendingActions = []
        confirmLines = nil
        dismiss()
    }
}
