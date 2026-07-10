import SwiftUI
import SwiftData
import LodoCore

/// 待办页:自然语言创建、到期卡片(完成/稍等)、待办与已完成列表。
struct TodoListView: View {
    /// tab 栏"添加"按钮置 true 后弹出快速添加页(见 ContentView)。
    @Binding var addRequested: Bool

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
        /// 快速添加页(自然语言 + 语音,仅 iOS)。
        case add
        case create(ParsedTask?)
        /// 编辑事项;AI 总入口路由到修改时带上解析出的新字段预填表单。
        case edit(TaskItem, ParsedTask?)

        var id: String {
            switch self {
            case .add: return "add"
            case .create: return "create"
            case .edit(let task, _): return task.uuid.uuidString
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
                case .add:
                    #if os(iOS)
                    AddTaskView { try await route($0) }
                    #endif
                case .create(let parsed):
                    TaskEditView(existing: nil, parsed: parsed) { saveNew($0) }
                case .edit(let task, let parsed):
                    TaskEditView(existing: task, parsed: parsed) { apply($0, to: task) }
                }
            }
            .onReceive(clock) { now = $0 }
            .onChange(of: addRequested) { _, requested in
                if requested {
                    addRequested = false
                    sheet = .add
                }
            }
            .onAppear {
                // 冷启动时深链可能先于本视图出现,补一次检查
                if addRequested {
                    addRequested = false
                    sheet = .add
                }
                #if DEBUG
                // 截图验证用:--demo-add 启动参数直接弹出快速添加页
                if ProcessInfo.processInfo.arguments.contains("--demo-add") {
                    sheet = .add
                }
                #endif
            }
        }
    }

    // MARK: - 区块

    private var nlSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                // axis: .vertical 让长占位文字与长输入换行显示,不再截断
                TextField("例如:明天3点开会一小时",
                          text: $nlText, axis: .vertical)
                    .lineLimit(1...3)
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
            Text("AI 助手")
        } footer: {
            Text("一句话新建事项,或直接说要改哪个事项;输入内容和当前待办列表会发送给 DeepSeek 解析。")
        }
    }

    private var dueSection: some View {
        // 与 web/android 的 "🔔 到期提醒" 对应;iOS 26 区块标题渲染不了 emoji
        // (显示为问号方块),改用同语义的 SF Symbol 铃铛。
        Section {
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
        } header: {
            Label("到期提醒", systemImage: "bell.fill")
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
                        sheet = .edit(task, nil)
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
                            WidgetBridge.sync(context: context)
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

    /// AI 总入口:带上当前待办列表,让模型判断是新建还是修改某个事项,
    /// 路由到对应表单。返回后用最新 pending 列表重新匹配 uuid。
    private func route(_ text: String) async throws {
        let context = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        switch try await DeepSeekClient.command(text, tasks: context) {
        case .create(let parsed):
            sheet = .create(parsed)
        case .update(let uuid, let parsed):
            guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else {
                throw DeepSeekError.parse("找不到要修改的事项")
            }
            sheet = .edit(task, parsed)
        }
    }

    private func parseNL() {
        let text = nlText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !aiBusy else { return }
        aiBusy = true
        aiError = nil
        Task {
            defer { aiBusy = false }
            do {
                try await route(text)
                nlText = ""
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
