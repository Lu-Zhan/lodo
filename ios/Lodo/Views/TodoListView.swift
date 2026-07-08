import SwiftUI
import SwiftData
import LodoCore

/// 待办页:自然语言创建、到期卡片(完成/稍等)、待办与已完成列表。
struct TodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]

    @State private var now = Date()
    @State private var nlText = ""
    @State private var aiBusy = false
    @State private var aiError: String?
    @State private var sheet: SheetMode?
    @State private var listMode: ListMode = .pending

    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    enum ListMode: String, CaseIterable {
        case pending = "待办"
        case done = "已完成"
    }

    enum SheetMode: Identifiable {
        case create(ParsedTask?)
        case edit(TaskItem)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let task): return task.uuid.uuidString
            }
        }
    }

    private var pending: [TaskItem] { allTasks.filter { $0.status == .pending } }
    private var due: [TaskItem] { pending.filter { $0.nextRemindAt <= now } }
    private var done: [TaskItem] {
        allTasks.filter { $0.status == .done }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                nlSection
                if !due.isEmpty {
                    dueSection
                }
                listSection
            }
            .navigationTitle("lodo")
            .toolbar {
                ToolbarItem {
                    Button {
                        sheet = .create(nil)
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $sheet) { mode in
                switch mode {
                case .create(let parsed):
                    TaskEditView(existing: nil, parsed: parsed) { saveNew($0) }
                case .edit(let task):
                    TaskEditView(existing: task, parsed: nil) { apply($0, to: task) }
                }
            }
            .onReceive(clock) { now = $0 }
        }
    }

    // MARK: - 区块

    private var nlSection: some View {
        Section {
            HStack {
                TextField("例如:明天下午3点开会一小时", text: $nlText)
                    .textFieldStyle(.plain)
                    .onSubmit { parseNL() }
                if aiBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        parseNL()
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .disabled(nlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let aiError {
                Text(aiError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("自然语言创建")
        }
    }

    private var dueSection: some View {
        Section("🔔 到期提醒") {
            ForEach(due) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.headline)
                    Text(dueCaption(task)).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            NotificationManager.shared.complete(task, context: context)
                        } label: {
                            Label(task.phase == .start && task.durationMinutes > 0
                                  ? "开始了" : "完成",
                                  systemImage: task.phase == .start && task.durationMinutes > 0
                                  ? "play.fill" : "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            NotificationManager.shared.snooze(task, context: context)
                        } label: {
                            Label("稍等 \(AppSettings.snoozeMinutes) 分钟", systemImage: "hourglass")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func dueCaption(_ task: TaskItem) -> String {
        if task.phase == .end { return "时间到 — 完成了吗?" }
        if task.durationMinutes > 0 {
            return "\(task.caption) — 该开始了!"
        }
        return task.caption
    }

    @ViewBuilder
    private var listSection: some View {
        Section {
            Picker("列表", selection: $listMode) {
                ForEach(ListMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch listMode {
            case .pending:
                if pending.isEmpty {
                    ContentUnavailableView("暂无待办事项", systemImage: "checkmark.circle")
                }
                ForEach(pending) { task in
                    Button {
                        sheet = .edit(task)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                            Text(task.caption).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            NotificationManager.shared.cancelChain(for: task.uuid)
                            context.delete(task)
                            try? context.save()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            NotificationManager.shared.complete(task, context: context)
                        } label: {
                            Label("完成", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                }
            case .done:
                if done.isEmpty {
                    ContentUnavailableView("还没有完成的事项", systemImage: "tray")
                }
                ForEach(done) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).strikethrough()
                        if let doneAt = task.doneAt {
                            Text("完成于 \(TaskItem.format(doneAt))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            context.delete(task)
                            try? context.save()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 动作

    private func parseNL() {
        let text = nlText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !aiBusy else { return }
        aiBusy = true
        aiError = nil
        Task {
            defer { aiBusy = false }
            do {
                let parsed = try await DeepSeekClient.parse(text)
                nlText = ""
                sheet = .create(parsed)
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    private func saveNew(_ parsed: ParsedTask) {
        let task = TaskItem(
            title: parsed.title, remindAt: parsed.remindAt,
            durationMinutes: parsed.durationMinutes, allDay: parsed.allDay,
            repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
            repeatTimes: parsed.repeatTimes)
        context.insert(task)
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    private func apply(_ parsed: ParsedTask, to task: TaskItem) {
        task.title = parsed.title
        task.remindAt = parsed.remindAt
        task.durationMinutes = parsed.durationMinutes
        task.allDay = parsed.allDay
        task.repeatTypeRaw = parsed.repeatType.rawValue
        task.repeatDays = parsed.repeatDays
        task.repeatTimes = parsed.repeatTimes
        task.phaseRaw = TaskPhase.start.rawValue
        task.nextRemindAt = parsed.remindAt
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }
}
