import SwiftUI
import SwiftData
import UserNotifications
import LodoCore
#if os(iOS)
import UIKit
#endif

/// 全局 agent 一次解析后的回应形态(AgentView 据此展示)。
enum AgentReply {
    /// 单条新建/修改:AgentView 叠一个 TaskEditView 在聊天页上面,
    /// 保存后由 AgentView 自己往当前 thread 追加一条结果消息。
    case routeToForm(existing: TaskItem?, parsed: ParsedTask)
    /// 需要确认的操作清单(批量或含完成/删除),元素为中文描述。
    case confirm([String])
    /// 关键信息缺失,反问 + 候选补充。
    case clarify(question: String, options: [String])
    /// 记忆问答的回答,或收藏回执;related 为相关条目标题(可为空),不做跳转。
    case answer(text: String, related: [String])
}

/// 记忆条目左滑"转为待办"交接的载荷(见 ContentView)。
struct ConvertToTodoRequest: Equatable {
    var title: String
    var attachment: TaskAttachment
}

/// AI 批量执行(performPendingActions)后留下的撤销记录,一条操作一个 case;
/// 复用备份功能已有的 BackupTask(展平字段 + apply(to:))做"改回原样"的载体,
/// 不用另起一套快照结构。只保留最近一批,执行新的批量操作或用掉一次撤销都会
/// 清空(见 TodoListView+Agent.swift 的 performUndo)。
enum UndoOp {
    case created(uuid: UUID)
    case updated(before: BackupTask)
    /// insertedHistoryUUID:重复事项完成一次时插入的历史记录,撤销要连它一起删掉。
    case completed(before: BackupTask, insertedHistoryUUID: UUID?)
    case deleted(before: BackupTask)
    /// 批次里混了 memorize 时新建的记忆条目;撤销把它删掉(连同它的向量分片,
    /// 走 MemoryPipeline.delete 同一套清理)。
    case memorized(uuid: UUID)
}

/// 待办页:横滑日期条(默认今天)、到期卡片(完成/稍等)、
/// 选中日待办与未来待办分组、已完成列表。
struct TodoListView: View {
    /// 非 nil 时弹出全局 agent 并预填文本(lodo://agent 深链,见 ContentView)。
    @Binding var agentRequest: String?
    /// tab 栏"添加"按钮触发时置 true:agent 弹出后自动开始语音。
    @Binding var agentAutoStart: Bool
    /// 非 nil 时跳到该事项并自动发起改期请求(通知"改期"按钮交接,见 ContentView)。
    @Binding var rescheduleRequestUUID: String?
    /// 非 nil 时弹出"新建事项"表单并预填标题+内容附件(记忆条目"转为待办"交接,见 ContentView)。
    @Binding var convertToTodoRequest: ConvertToTodoRequest?

    // 以下几个跨 extension 文件(TodoListView+Agent/+Reschedule/+CRUD)被读写,
    // 不能用 private(Swift 的 private 只对同一文件可见),保持 internal。
    @Environment(\.modelContext) var context
    @Environment(\.scenePhase) private var scenePhase
    /// 只查未完成事项,已完成事项在待办页底部单独折叠展示。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    /// 已完成事项并入待办页底部,默认折叠展示。TodoListView+Agent.swift 的撤销
    /// 逻辑也要按 uuid 查已完成事项(如撤销"完成"本身),不能用 private。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "done" },
           sort: [SortDescriptor(\TaskItem.doneAt, order: .reverse)])
    var doneTasks: [TaskItem]

    @AppStorage(AppSettings.insightEnabledKey) private var insightEnabled = true

    @State private var now = Date()
    // consumeReschedule (TodoListView+Reschedule.swift) 需要跳日期,保持 internal。
    @State var selectedDate = Calendar.current.startOfDay(for: Date())
    @State var sheet: SheetMode?
    /// agent 解析出、等待用户确认的批量操作。
    @State var pendingActions: [AIAction] = []
    /// 上一批 AI 执行完的操作,供"撤销"用;见 TodoListView+Agent.swift。
    @State var lastUndo: [UndoOp]?
    /// lastUndo 是哪个 thread 的批量操作留下的;AI 助手可以同时开好几个 thread,
    /// 在 thread A 执行完切到 thread B 又执行一批,thread A 那条"已完成执行"
    /// 气泡的撤销按钮还在(它在自己 thread 里仍是最新消息),但不能真的撤销
    /// thread B 的操作——撤销前先核对这个 uuid 对不对。
    @State var lastUndoThreadUUID: UUID?
    /// 到期卡改期:请求中的事项 uuid / 已返回的候选 / 错误 / 进行中的请求。
    @State var rescheduleLoading: String?
    @State var reschedule: (uuid: String, candidates: [(label: String, date: Date)])?
    @State var rescheduleError: String?
    @State var rescheduleTask: Task<Void, Never>?
    /// 完成后询问实际耗时的轻量条(队列,连续完成不互相覆盖)。
    @State var askDurationQueue: [(title: String, planned: Int)] = []
    /// 通知权限被拒绝(app 内唯一提醒渠道失效)时提示用户去系统设置开启。
    @State private var notificationsDenied = false
    /// 批量 agent 操作里有目标事项在确认期间被别处改动/删除时的提示。
    @State var actionsWarning: String?
    @State private var doneExpanded = false
    @State private var expandedDoneDays: Set<Date> = []
    @State private var insight: String?

    /// 日期条展示的天数(从今天起)。
    private static let stripDays = 30
    private static let insightWeekKey = "insightWeek"
    private static let insightTextKey = "insightText"

    enum SheetMode: Identifiable {
        /// 全局 agent(一句话新增/修改);深链/tab 按钮可带预填文本,
        /// autoStart 为 true 时弹出后自动开始语音(仅 tab 按钮/小组件"+"触发)。
        case agent(prefill: String?, autoStart: Bool)
        /// attachment 非 nil 时来自记忆条目"转为待办"。
        case create(ParsedTask?, TaskAttachment?)
        /// 编辑事项;agent 路由到修改时带上解析出的新字段预填表单。
        case edit(TaskItem, ParsedTask?)
        case settings

        var id: String {
            switch self {
            case .agent: return "agent"
            case .create: return "create"
            case .edit(let task, _): return task.uuid.uuidString
            case .settings: return "settings"
            }
        }
    }

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
    /// 今天完成的事项:保持平铺展示,不参与日期折叠。
    private var todayDone: [TaskItem] {
        doneTasks.filter { Calendar.current.isDateInToday($0.doneAt ?? .distantPast) }
    }
    /// 其他日期完成的事项:按完成日分组,日期倒序,默认折叠。
    private var otherDoneGroups: [(date: Date, tasks: [TaskItem])] {
        let calendar = Calendar.current
        let others = doneTasks.filter { !calendar.isDateInToday($0.doneAt ?? .distantPast) }
        let groups = Dictionary(grouping: others) { calendar.startOfDay(for: $0.doneAt ?? .distantPast) }
        return groups.sorted { $0.key > $1.key }.map { (date: $0.key, tasks: $0.value) }
    }
    /// 下一次需要唤醒刷新 `now` 的时刻:最近一个未到期事项或明天零点,取早者。
    private var nextWakeDate: Date {
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        let nextDue = pending.map(\.nextRemindAt).filter { $0 > now }.min()
        return min(nextDue ?? midnight, midnight)
    }

    var body: some View {
        NavigationStack {
            List {
                if notificationsDenied {
                    notificationDeniedSection
                }
                dateStrip
                if let ask = askDurationQueue.first {
                    askDurationSection(ask)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if !due.isEmpty {
                    dueSection
                }
                daySection
                if !futureTasks.isEmpty {
                    futureSection
                }
                doneSection
            }
            .animation(.snappy, value: due.map(\.uuid))
            .animation(.snappy, value: askDurationQueue.map(\.title))
            .animation(.snappy, value: selectedDate)
            .animation(.snappy, value: doneExpanded)
            .navigationTitle("lodo")
            .toolbar {
                #if os(macOS)
                // macOS 没有下拉手势,agent 入口放工具栏;短按打开/回到最近对话,
                // 长按直接开语音(与 iOS 悬浮按钮同一套交互,见 ContentView.swift)。
                ToolbarItem {
                    Button {
                        sheet = .agent(prefill: nil, autoStart: false)
                    } label: {
                        Label("AI 助手", systemImage: "sparkles")
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            sheet = .agent(prefill: nil, autoStart: true)
                        }
                    )
                }
                #endif
                ToolbarItem {
                    Button {
                        sheet = .settings
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .sheet(item: $sheet, onDismiss: {
                // 清掉 agent 会话残留,避免旧的批量操作被后续"确认执行";
                // 并消费 sheet 打开期间积压的深链路由
                pendingActions = []
                DispatchQueue.main.async { consumeRoutes() }
            }) { mode in
                switch mode {
                case .agent(let prefill, let autoStart):
                    AgentView(prefill: prefill, autoStart: autoStart,
                              submit: { text, threadUUID, history, onThought in
                                  try await route(text, threadUUID: threadUUID,
                                                  history: history, onThought: onThought)
                              },
                              onConfirm: { performPendingActions(threadUUID: $0) },
                              onUndo: { performUndo(threadUUID: $0) },
                              saveTask: { existing, parsed in
                                  if let existing {
                                      apply(parsed, to: existing)
                                  } else {
                                      saveNew(parsed)
                                  }
                              })
                case .create(let parsed, let attachment):
                    TaskEditView(existing: nil, parsed: parsed, attachment: attachment) {
                        saveNew($0, attachment: attachment)
                    }
                case .edit(let task, let parsed):
                    TaskEditView(existing: task, parsed: parsed, attachment: task.attachment) {
                        apply($0, to: task)
                    }
                case .settings:
                    SettingsView()
                }
            }
            // 按需唤醒:睡到下一个到期时刻/明天零点再刷新 now,替代固定 10 秒轮询
            .task(id: nextWakeDate) {
                let interval = nextWakeDate.timeIntervalSinceNow + 1
                if interval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                now = Date()
            }
            .onChange(of: agentRequest) { _, request in
                if request != nil { consumeRoutes() }
            }
            .onChange(of: rescheduleRequestUUID) { _, uuid in
                consumeReschedule(uuid)
            }
            .onChange(of: convertToTodoRequest) { _, request in
                consumeConvertToTodo(request)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { checkNotificationAuthorization() }
            }
            .onChange(of: doneExpanded) { _, expanded in
                if expanded {
                    Task { await loadInsight() }
                }
            }
            .alert("提示", isPresented: Binding(
                get: { actionsWarning != nil },
                set: { if !$0 { actionsWarning = nil } }
            )) {
                Button("好", role: .cancel) { actionsWarning = nil }
            } message: {
                Text(actionsWarning ?? "")
            }
            .onAppear {
                // 冷启动时深链可能先于本视图出现,补一次检查
                consumeRoutes()
                consumeReschedule(rescheduleRequestUUID)
                consumeConvertToTodo(convertToTodoRequest)
                checkNotificationAuthorization()
                #if DEBUG
                // 截图验证用:--demo-agent 启动参数直接弹出 AI 助手
                if ProcessInfo.processInfo.arguments.contains("--demo-agent") {
                    sheet = .agent(prefill: nil, autoStart: false)
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-settings") {
                    sheet = .settings
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-reschedule"),
                   let first = due.first {
                    reschedule = (first.uuid.uuidString, [
                        (label: "今晚 20:00", date: Date().addingTimeInterval(6 * 3600)),
                        (label: "明早 9:00", date: Date().addingTimeInterval(19 * 3600)),
                        (label: "周六上午", date: Date().addingTimeInterval(48 * 3600)),
                    ])
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-ask-duration") {
                    askDurationQueue.append((title: "开周会", planned: 60))
                }
                #endif
            }
        }
    }

    // MARK: - 通知权限

    /// 通知是纠缠式提醒唯一的推送渠道;权限被拒时提示用户,否则提醒会静默失效。
    private var notificationDeniedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("通知权限已关闭,提醒不会推送", systemImage: "bell.slash.fill")
                    .foregroundStyle(.orange)
                #if os(iOS)
                Button("前往系统设置开启") { openNotificationSettings() }
                    .buttonStyle(.bordered)
                #endif
            }
            .padding(.vertical, 2)
        }
    }

    private func checkNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationsDenied = settings.authorizationStatus == .denied
            }
        }
    }

    #if os(iOS)
    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    #endif

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
            withAnimation(.snappy) { selectedDate = date }
        } label: {
            VStack(spacing: 2) {
                Text(calendar.isDateInToday(date) ? "今天" : weekdayNames[weekdayIndex])
                    .font(.caption2)
                Text("\(calendar.component(.day, from: date))")
                    .font(.headline)
            }
            .lineLimit(1)
            .frame(minWidth: 46, minHeight: 54)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(date.formatted(.dateTime.month().day().weekday()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 区块

    private var dueSection: some View {
        // 与 web/android 的 "🔔 到期提醒" 对应;iOS 26 区块标题渲染不了 emoji
        // (显示为问号方块),改用同语义的 SF Symbol 铃铛。
        Section {
            ForEach(due) { task in
                VStack(alignment: .leading, spacing: 8) {
                    // 标题行:完成/改期/稍等都改成左右滑手势,行内不再放按钮
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.title).font(.headline)
                        if rescheduleLoading == task.uuid.uuidString {
                            Spacer()
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在改期")
                        }
                    }
                    Text(dueCaption(task)).font(.footnote).foregroundStyle(.secondary)
                    if let reschedule, reschedule.uuid == task.uuid.uuidString {
                        HorizontalChipRow {
                            ForEach(reschedule.candidates, id: \.label) { candidate in
                                Button(candidate.label) {
                                    applyReschedule(task, to: candidate.date)
                                }
                                .buttonStyle(.bordered)
                                .font(.footnote)
                                .tint(.accentColor)
                            }
                            Button {
                                withAnimation(.snappy) { self.reschedule = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            #if os(iOS)
                            .hoverEffect(.highlight)
                            #endif
                            .accessibilityLabel("收起改期候选")
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .leading) {
                    Button {
                        Haptics.success()
                        completeWithSampling(task)
                    } label: {
                        Label(task.phase == .start && task.durationMinutes > 0
                              ? "开始了" : "完成",
                              systemImage: task.phase == .start && task.durationMinutes > 0
                              ? "play.fill" : "checkmark")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    // 改期是第一个 action:长滑(full swipe)直接触发它;
                    // 稍等作为第二个 action,短滑露出后需要点按。
                    Button {
                        requestReschedule(task)
                    } label: {
                        Label("改期", systemImage: "calendar.badge.clock")
                    }
                    .tint(.blue)
                    .disabled(rescheduleLoading != nil)
                    Button {
                        NotificationManager.shared.snooze(task, context: context)
                    } label: {
                        Text("+\(AppSettings.snoozeMinutes)M")
                    }
                    .tint(.orange)
                    .accessibilityLabel("稍等 \(AppSettings.snoozeMinutes) 分钟")
                }
            }
            if let rescheduleError {
                Text(rescheduleError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Label("到期提醒", systemImage: "bell.fill")
        }
    }

    /// 完成后的实际耗时轻量条(智能采样,队列化;选择/跳过后出下一条)。
    private func askDurationSection(_ ask: (title: String, planned: Int)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("「\(ask.title)」实际用了多久?").font(.subheadline)
                HorizontalChipRow {
                    ForEach(durationChips(planned: ask.planned), id: \.self) { minutes in
                        Button("\(minutes) 分钟") {
                            Haptics.success()
                            DurationMemory.recordActual(
                                title: ask.title, planned: ask.planned, minutes: minutes)
                            popAskDuration()
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                    }
                    Button("跳过") { popAskDuration() }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 选中日期的待办;与未来待办分开成组。
    private var daySection: some View {
        Section {
            if upcoming.isEmpty && due.isEmpty {
                ContentUnavailableView {
                    Label("暂无待办事项", systemImage: "checkmark.circle")
                } description: {
                    Text("跟 AI 说一句话就能新建,比如「明天下午3点开会」。")
                } actions: {
                    Button("开始添加") { sheet = .agent(prefill: nil, autoStart: false) }
                        .glassProminentButton()
                }
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

    private var doneSection: some View {
        Section {
            DisclosureGroup(isExpanded: $doneExpanded) {
                if insightEnabled, let insight {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本周洞察")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(insight, systemImage: "sparkles")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
                if doneTasks.isEmpty {
                    ContentUnavailableView("还没有完成的事项", systemImage: "tray")
                }
                if !todayDone.isEmpty {
                    Text("今天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(todayDone) { task in
                        doneRow(task)
                    }
                }
                ForEach(otherDoneGroups, id: \.date) { group in
                    DisclosureGroup(dayGroupTitle(group.date),
                                    isExpanded: doneDayExpandedBinding(for: group.date)) {
                        ForEach(group.tasks) { task in
                            doneRow(task)
                        }
                    }
                }
            } label: {
                Label("已完成", systemImage: "checkmark.circle")
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
        .nagSwipeActions(
            leadingLabel: "完成", leadingSystemImage: "checkmark", leadingTint: .green,
            onLeading: { completeWithSampling(task) },
            onDelete: {
                NotificationManager.shared.cancelChain(for: task.uuid)
                withAnimation(.snappy) {
                    context.delete(task)
                }
                try? context.save()
                WidgetBridge.sync(context: context)
            })
    }

    private func doneRow(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).strikethrough()
            if let doneAt = task.doneAt {
                Text("完成于 \(TaskItem.format(doneAt))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .nagSwipeActions(
            leadingLabel: "未完成", leadingSystemImage: "arrow.uturn.backward", leadingTint: .orange,
            onLeading: { restoreDoneTask(task) },
            onDelete: {
                context.delete(task)
                try? context.save()
            })
    }

    private func doneDayExpandedBinding(for date: Date) -> Binding<Bool> {
        Binding(
            get: { expandedDoneDays.contains(date) },
            set: { isExpanded in
                if isExpanded {
                    expandedDoneDays.insert(date)
                } else {
                    expandedDoneDays.remove(date)
                }
            }
        )
    }

    private func dayGroupTitle(_ date: Date) -> String {
        Calendar.current.isDateInYesterday(date)
            ? "昨天"
            : date.formatted(.dateTime.month().day())
    }

    /// 恢复为待办:回到 start 阶段,提醒时间取原定时间(已过期会直接进到期卡)。
    private func restoreDoneTask(_ task: TaskItem) {
        task.statusRaw = TaskStatus.pending.rawValue
        task.phaseRaw = TaskPhase.start.rawValue
        task.doneAt = nil
        task.nextRemindAt = task.remindAt
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    /// 每周完成洞察:本地统计近 7 天完成情况,AI 只负责说成一句正向的话;
    /// 同一 ISO 周缓存,失败静默不显示。
    private func loadInsight() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-insight") {
            insight = "这周完成 12 件,比上周多 3 件;晚上 9 点后你的完成率最高,阅读类放晚上试试。"
            return
        }
        #endif
        guard insightEnabled, DeepSeekClient.isConfigured else { return }
        let calendar = Calendar.current
        let stamp = "\(calendar.component(.yearForWeekOfYear, from: Date()))-" +
            "\(calendar.component(.weekOfYear, from: Date()))"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.insightWeekKey) == stamp,
           let cached = defaults.string(forKey: Self.insightTextKey) {
            insight = cached
            return
        }
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 86400)
        let recent = doneTasks.filter { ($0.doneAt ?? .distantPast) > weekAgo }
        guard !recent.isEmpty else { return }
        let previous = doneTasks.filter {
            let doneAt = $0.doneAt ?? .distantPast
            return doneAt > twoWeeksAgo && doneAt <= weekAgo
        }
        var stats = "近 7 天完成 \(recent.count) 件(再往前 7 天完成 \(previous.count) 件)"
        let hours = recent.compactMap { task in
            task.doneAt.map { calendar.component(.hour, from: $0) }
        }
        if let topHour = Dictionary(grouping: hours, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            stats += ";最常完成时段:\(topHour) 点左右"
        }
        stats += ";最近完成:" + recent.prefix(5).map(\.title).joined(separator: "、")
        guard let text = try? await DeepSeekClient.weeklyInsight(stats: stats) else { return }
        defaults.set(stamp, forKey: Self.insightWeekKey)
        defaults.set(text, forKey: Self.insightTextKey)
        insight = text
    }

    // 全局 agent 路由/批量确认、改期请求、CRUD 等逻辑拆到同目录的
    // TodoListView+Agent.swift / +Reschedule.swift / +CRUD.swift。
}
