import SwiftUI
import SwiftData
import LodoCore

/// 全局 agent 一次解析后的回应形态(AgentView 据此展示)。
enum AgentReply {
    /// 已直达表单(单条新建/修改),agent 页无事可做。
    case routed
    /// 需要确认的操作清单(批量或含完成/删除),元素为中文描述。
    case confirm([String])
    /// 关键信息缺失,反问 + 候选补充。
    case clarify(question: String, options: [String])
}

/// 待办页:横滑日期条(默认今天)、到期卡片(完成/稍等)、
/// 选中日待办与未来待办分组、已完成列表。
struct TodoListView: View {
    /// tab 栏"添加"按钮置 true 后弹出快速添加页(见 ContentView)。
    @Binding var addRequested: Bool
    /// 非 nil 时弹出全局 agent 并预填文本(lodo://agent 深链,见 ContentView)。
    @Binding var agentRequest: String?

    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]

    @State private var now = Date()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var sheet: SheetMode?
    /// agent 解析出、等待用户确认的批量操作。
    @State private var pendingActions: [AIAction] = []

    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    /// 日期条展示的天数(从今天起)。
    private static let stripDays = 30

    enum SheetMode: Identifiable {
        /// 快速添加页(自然语言 + 语音 + 手动,仅 iOS)。
        case add
        /// 主页下拉唤出的全局 agent(一句话新增/修改,仅 iOS);深链可带预填文本。
        case agent(prefill: String?)
        case create(ParsedTask?)
        /// 编辑事项;agent 路由到修改时带上解析出的新字段预填表单。
        case edit(TaskItem, ParsedTask?)
        case settings

        var id: String {
            switch self {
            case .add: return "add"
            case .agent: return "agent"
            case .create: return "create"
            case .edit(let task, _): return task.uuid.uuidString
            case .settings: return "settings"
            }
        }
    }

    private var pending: [TaskItem] { allTasks.filter { $0.status == .pending } }
    private var due: [TaskItem] { pending.filter { $0.nextRemindAt <= now } }
    /// 尚未到期的待办(已到期的在到期卡片区)。
    private var upcoming: [TaskItem] { pending.filter { $0.nextRemindAt > now } }
    private var dayTasks: [TaskItem] {
        upcoming.filter { Calendar.current.isDate($0.nextRemindAt, inSameDayAs: selectedDate) }
    }
    private var futureTasks: [TaskItem] {
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1,
                                                  to: selectedDate) else { return [] }
        return upcoming.filter { $0.nextRemindAt >= nextDay }
    }
    var body: some View {
        NavigationStack {
            List {
                dateStrip
                if !due.isEmpty {
                    dueSection
                }
                daySection
                if !futureTasks.isEmpty {
                    futureSection
                }
            }
            .navigationTitle("lodo")
            .toolbar {
                ToolbarItem {
                    Button {
                        sheet = .settings
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .sheet(item: $sheet) { mode in
                switch mode {
                case .add:
                    #if os(iOS)
                    AddTaskView(onSaveManual: { saveNew($0) })
                    #endif
                case .agent(let prefill):
                    #if os(iOS)
                    AgentView(prefill: prefill,
                              submit: { try await route($0) },
                              onConfirm: { performPendingActions() })
                    #endif
                case .create(let parsed):
                    TaskEditView(existing: nil, parsed: parsed) { saveNew($0) }
                case .edit(let task, let parsed):
                    TaskEditView(existing: task, parsed: parsed) { apply($0, to: task) }
                case .settings:
                    SettingsView()
                }
            }
            #if os(iOS)
            // 下拉唤出全局 agent(一句话新增/修改待办)
            .refreshable {
                sheet = .agent(prefill: nil)
            }
            #endif
            .onReceive(clock) { now = $0 }
            .onChange(of: addRequested) { _, requested in
                if requested {
                    addRequested = false
                    sheet = .add
                }
            }
            .onChange(of: agentRequest) { _, request in
                if let request {
                    agentRequest = nil
                    sheet = .agent(prefill: request.isEmpty ? nil : request)
                }
            }
            .onAppear {
                // 冷启动时深链可能先于本视图出现,补一次检查
                if addRequested {
                    addRequested = false
                    sheet = .add
                }
                if let request = agentRequest {
                    agentRequest = nil
                    sheet = .agent(prefill: request.isEmpty ? nil : request)
                }
                #if DEBUG
                // 截图验证用:--demo-add 启动参数直接弹出快速添加页
                if ProcessInfo.processInfo.arguments.contains("--demo-add") {
                    sheet = .add
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent") {
                    sheet = .agent(prefill: nil)
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-settings") {
                    sheet = .settings
                }
                #endif
            }
        }
    }

    // MARK: - 日期条

    /// 从今天起横向滑动选择日期,默认选中今天。
    private var dateStrip: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<Self.stripDays, id: \.self) { offset in
                        if let date = Calendar.current.date(
                            byAdding: .day, value: offset,
                            to: Calendar.current.startOfDay(for: now)) {
                            dayCell(date)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        // 用默认列表行背景铺白色卡片,圆角与下方模块一致
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    private func dayCell(_ date: Date) -> some View {
        let calendar = Calendar.current
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let weekdayIndex = (calendar.component(.weekday, from: date) + 5) % 7
        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(calendar.isDateInToday(date) ? "今天" : weekdayNames[weekdayIndex])
                    .font(.caption2)
                Text("\(calendar.component(.day, from: date))")
                    .font(.headline)
            }
            .frame(width: 46, height: 54)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 区块

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

    /// 选中日期的待办;与未来待办分开成组。
    private var daySection: some View {
        Section {
            if upcoming.isEmpty && due.isEmpty {
                ContentUnavailableView("暂无待办事项", systemImage: "checkmark.circle")
            } else if dayTasks.isEmpty {
                Text("当天暂无待办").foregroundStyle(.secondary)
            }
            ForEach(dayTasks) { task in
                pendingRow(task)
            }
        } header: {
            Text(dayHeaderTitle)
        }
    }

    private var dayHeaderTitle: String {
        Calendar.current.isDateInToday(selectedDate)
            ? "今天待办"
            : "\(selectedDate.formatted(.dateTime.month().day()))待办"
    }

    private var futureSection: some View {
        Section("未来待办") {
            ForEach(futureTasks) { task in
                pendingRow(task)
            }
        }
    }

    private func pendingRow(_ task: TaskItem) -> some View {
        Button {
            sheet = .edit(task, nil)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                Text(task.caption).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        // 右滑(满滑)完成
        .swipeActions(edge: .leading) {
            Button {
                Haptics.success()
                NotificationManager.shared.complete(task, context: context)
            } label: {
                Label("完成", systemImage: "checkmark")
            }
            .tint(.green)
        }
        // 左滑(满滑)删除
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Haptics.impact()
                NotificationManager.shared.cancelChain(for: task.uuid)
                context.delete(task)
                try? context.save()
                WidgetBridge.sync(context: context)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 动作

    /// 全局 agent:带上当前待办列表,把一句话解析成操作。
    /// 单条新建/修改直达表单(表单即确认);批量或含完成/删除的进确认清单;
    /// 关键信息缺失时透传反问。uuid 用最新 pending 列表重新匹配。
    private func route(_ text: String) async throws -> AgentReply {
        let context = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        switch try await DeepSeekClient.command(text, tasks: context) {
        case .clarify(let question, let options):
            return .clarify(question: question, options: options)
        case .actions(let actions):
            if actions.count == 1 {
                if case .create(let parsed) = actions[0] {
                    sheet = .create(parsed)
                    return .routed
                }
                if case .update(let uuid, let parsed) = actions[0] {
                    guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else {
                        throw DeepSeekError.parse("找不到要修改的事项")
                    }
                    sheet = .edit(task, parsed)
                    return .routed
                }
            }
            pendingActions = actions
            return .confirm(actions.map(describe))
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
        }
    }

    private func title(of uuid: String) -> String? {
        pending.first { $0.uuid.uuidString == uuid }?.title
    }

    /// 执行确认后的批量操作,完毕关闭 agent。
    private func performPendingActions() {
        for action in pendingActions {
            switch action {
            case .create(let parsed):
                saveNew(parsed)
            case .update(let uuid, let parsed):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    apply(parsed, to: task)
                }
            case .complete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    NotificationManager.shared.complete(task, context: context)
                }
            case .delete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    NotificationManager.shared.cancelChain(for: task.uuid)
                    context.delete(task)
                }
            }
        }
        pendingActions = []
        try? context.save()
        WidgetBridge.sync(context: context)
        sheet = nil
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
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
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
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
    }
}
