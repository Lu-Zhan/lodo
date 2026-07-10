import SwiftUI
import SwiftData
import LodoCore

/// 待办页:横滑日期条(默认今天)、到期卡片(完成/稍等)、
/// 选中日待办与未来待办分组、已完成列表。
struct TodoListView: View {
    /// tab 栏"添加"按钮置 true 后弹出快速添加页(见 ContentView)。
    @Binding var addRequested: Bool

    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]

    @State private var now = Date()
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var sheet: SheetMode?

    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    /// 日期条展示的天数(从今天起)。
    private static let stripDays = 30

    enum SheetMode: Identifiable {
        /// 快速添加页(自然语言 + 语音 + 手动,仅 iOS)。
        case add
        /// 主页下拉唤出的全局 agent(一句话新增/修改,仅 iOS)。
        case agent
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
                case .agent:
                    #if os(iOS)
                    AgentView { try await route($0) }
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
                sheet = .agent
            }
            #endif
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
                if ProcessInfo.processInfo.arguments.contains("--demo-agent") {
                    sheet = .agent
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

    /// 全局 agent:带上当前待办列表,让模型判断是新建还是修改某个事项,
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
