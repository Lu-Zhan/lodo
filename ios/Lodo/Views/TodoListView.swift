import SwiftUI
import SwiftData
import UserNotifications
import LodoCore
#if os(iOS)
import UIKit
#endif

/// 全局 agent 一次解析后的回应形态(AgentView 据此展示)。
enum AgentReply {
    /// 单条新建/修改:AgentView 追加一条待确认的 taskProposal 气泡(内联卡片 +
    /// Cancel/Confirm),点卡片本身可跳到 TaskEditView 微调。
    case routeToForm(existing: TaskItem?, parsed: ParsedTask)
    /// 需要确认的操作清单(批量或含完成/删除),元素为中文描述。
    case confirm([String])
    /// 关键信息缺失,反问用户:AgentView 追加一条可交互的询问卡(可翻页、
    /// 单选/多选、带推荐项),答完后把选择静默回传给 AI 继续出最终 actions。
    case ask([AskQuestion])
    /// 记忆问答的回答;related 为相关条目标题(可为空),不做跳转。
    case answer(text: String, related: [String])
    /// AI 主动建议收藏(用户没明确要求);气泡上带"收藏这条"按钮,点了才真正落库。
    case suggestMemorize(text: String)
    /// 单条收藏已直接落库(memorize),AgentView 据 uuid 展示记忆结果卡片。
    case memorized(uuid: UUID)
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

/// 待办页:顶部 4 个筛选胶囊(今天/未来/全部/已完成)、到期卡片(完成/稍等,
/// 不受筛选影响永远显示)、按筛选态切换的待办/已完成列表。
struct TodoListView: View {
    /// 非 nil 时弹出全局 agent 并预填文本(lodo://agent 深链,见 ContentView)。
    @Binding var agentRequest: String?
    /// 非 nil 时弹出"新建事项"表单并预填标题+内容附件(记忆条目"转为待办"交接,见 ContentView)。
    @Binding var convertToTodoRequest: ConvertToTodoRequest?

    // 以下几个跨 extension 文件(TodoListView+Agent/+CRUD)被读写,
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
    /// 顶部 4 个筛选胶囊(今天/未来/全部/已完成)当前选中的态。
    @State var filter: TodoFilter = .today
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
    /// 完成后询问实际耗时的轻量条(队列,连续完成不互相覆盖)。
    @State var askDurationQueue: [(title: String, planned: Int)] = []
    /// 通知权限被拒绝(app 内唯一提醒渠道失效)时提示用户去系统设置开启。
    @State private var notificationsDenied = false
    /// 批量 agent 操作里有目标事项在确认期间被别处改动/删除时的提示。
    @State var actionsWarning: String?
    @State private var insight: String?

    private static let insightWeekKey = "insightWeek"
    private static let insightTextKey = "insightText"

    /// 顶部筛选胶囊的 4 个态;"全部"/"已完成"按日期分 Section,其余两个是平铺列表。
    enum TodoFilter: CaseIterable {
        case today, future, all, done

        var title: String {
            switch self {
            case .today: return "今天"
            case .future: return "未来"
            case .all: return "全部"
            case .done: return "已完成"
            }
        }
    }

    enum SheetMode: Identifiable {
        /// 全局 agent(一句话新增/修改);深链/tab 按钮可带预填文本,打开后统一
        /// 唤起键盘(语音改成手动点麦克风图标触发)。
        case agent(prefill: String?)
        /// attachment 非 nil 时来自记忆条目"转为待办"。
        case create(ParsedTask?, TaskAttachment?)
        /// 编辑事项;agent 路由到修改时带上解析出的新字段预填表单。
        case edit(TaskItem, ParsedTask?)

        var id: String {
            switch self {
            case .agent: return "agent"
            case .create: return "create"
            case .edit(let task, _): return task.uuid.uuidString
            }
        }
    }

    #if os(iOS)
    private var isAgentFullScreen: Bool {
        if case .agent = sheet { return true }
        return false
    }

    private var fullScreenAgentBinding: Binding<SheetMode?> {
        Binding(get: { isAgentFullScreen ? sheet : nil }, set: { if $0 == nil { sheet = nil } })
    }

    private var cardSheetBinding: Binding<SheetMode?> {
        Binding(get: { isAgentFullScreen ? nil : sheet }, set: { if $0 == nil { sheet = nil } })
    }
    #endif

    /// 清掉 agent 会话残留,避免旧的批量操作被后续"确认执行";
    /// 并消费 sheet/fullScreenCover 打开期间积压的深链路由。
    private func handleSheetDismiss() {
        pendingActions = []
        DispatchQueue.main.async { consumeRoutes() }
    }

    @ViewBuilder
    private func sheetContent(_ mode: SheetMode) -> some View {
        switch mode {
        case .agent(let prefill):
            AgentView(prefill: prefill,
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
        }
    }

    private var due: [TaskItem] { pending.filter { $0.nextRemindAt <= now } }
    /// 尚未到期的待办。
    private var upcoming: [TaskItem] { pending.filter { $0.nextRemindAt > now } }
    /// 待办分组时算作哪一天:到期未处理的(不管原定哪天,含昨天及更早遗漏的)
    /// 一律冒泡算作"今天"——过期的待办不该被埋没在过去的日期分组里没人看见;
    /// 没到期的按 `nextRemindAt` 本身的日期算。行内时间靠这个信号标红,见 taskRow。
    private func effectiveDay(_ task: TaskItem) -> Date {
        let calendar = Calendar.current
        if task.nextRemindAt <= now { return calendar.startOfDay(for: now) }
        return calendar.startOfDay(for: task.nextRemindAt)
    }
    /// "今天"筛选态的内容:今天该做的 + 全部到期未处理的,按提醒时间升序——
    /// 到期项 nextRemindAt 更早,自然排在前面,不用额外排序。
    private var todayTasks: [TaskItem] {
        let today = Calendar.current.startOfDay(for: now)
        return pending.filter { effectiveDay($0) == today }
    }
    /// "未来"筛选态的内容:今天以后,平铺不分组(每行自带日期,见 TaskItem.caption)。
    private var futureTasks: [TaskItem] {
        upcoming.filter { !Calendar.current.isDateInToday($0.nextRemindAt) }
    }
    /// "全部"筛选态的内容:全部待办(含到期未处理的)按天分组、升序;
    /// 到期项同样冒泡进"今天"那组。
    private var allGroupedByDay: [(date: Date, tasks: [TaskItem])] {
        let groups = Dictionary(grouping: pending) { effectiveDay($0) }
        return groups.sorted { $0.key < $1.key }.map { (date: $0.key, tasks: $0.value) }
    }
    /// "已完成"筛选态的内容:全部已完成事项按完成日分组、降序(最近完成的在前)。
    private var doneGroupedByDay: [(date: Date, tasks: [TaskItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: doneTasks) { calendar.startOfDay(for: $0.doneAt ?? .distantPast) }
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
                filterBar
                if let ask = askDurationQueue.first {
                    askDurationSection(ask)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                switch filter {
                case .today: todaySection
                case .future: futureSection
                case .all: allSections
                case .done: doneSections
                }
            }
            .animation(.snappy, value: due.map(\.uuid))
            .animation(.snappy, value: askDurationQueue.map(\.title))
            .animation(.snappy, value: filter)
            .navigationTitle("待办")
            .toolbar {
                #if os(macOS)
                // macOS 没有下拉手势,agent 入口放工具栏(与 iOS 悬浮按钮同一套交互,
                // 见 ContentView.swift)。
                ToolbarItem {
                    Button {
                        sheet = .agent(prefill: nil)
                    } label: {
                        Label("AI 助手", systemImage: "sparkles")
                    }
                }
                #endif
            }
            #if os(iOS)
            // iOS(iPhone、iPad,不分宽窄屏)上 agent 恒走 fullScreenCover 而不是
            // sheet 卡片:sheet 卡片在 iPad 上宽度固定在 ~580pt,低于 regular/compact
            // 断点,AgentView 内部拿到的 horizontalSizeClass 会一直是 .compact,常驻
            // 侧栏(regularLayout)用不上;全屏展示则如实继承外层的 size class,iPhone
            // 仍是 .compact(抽屉),iPad regular 宽度才是 .regular(常驻列)。
            // macOS 不在这个范围内,继续用下面 #else 分支的窗口 sheet
            // (horizontalSizeClass 在 macOS 上恒为 .regular,已经足够宽)。
            .sheet(item: cardSheetBinding, onDismiss: handleSheetDismiss) { mode in
                sheetContent(mode)
            }
            .fullScreenCover(item: fullScreenAgentBinding, onDismiss: handleSheetDismiss) { mode in
                sheetContent(mode)
            }
            #else
            .sheet(item: $sheet, onDismiss: handleSheetDismiss) { mode in
                sheetContent(mode)
            }
            #endif
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
            .onChange(of: convertToTodoRequest) { _, request in
                consumeConvertToTodo(request)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { checkNotificationAuthorization() }
            }
            .onChange(of: filter) { _, new in
                if new == .done {
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
                consumeConvertToTodo(convertToTodoRequest)
                checkNotificationAuthorization()
                #if DEBUG
                // 截图验证用:--demo-agent 启动参数直接弹出 AI 助手
                if ProcessInfo.processInfo.arguments.contains("--demo-agent") {
                    sheet = .agent(prefill: nil)
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-ask-duration") {
                    askDurationQueue.append((title: "开周会", planned: 60))
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-seed-data"), pending.isEmpty {
                    seedDemoData()
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-filter-all") {
                    filter = .all
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-filter-done") {
                    filter = .done
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

    // MARK: - 筛选胶囊

    /// 顶部常驻的 4 个大号筛选胶囊,替代原来的横滑日期条;单选,选中态用
    /// .borderedProminent 填充色,未选中用 .bordered 描边——与 MemoryListView
    /// 筛选弹层的 tag 胶囊(.buttonBorderShape(.capsule))同一视觉语言,只是
    /// 这里是主导航控件,字号/触控区域做大一档。不铺白色卡片背景、不撑满
    /// 横向宽度,胶囊挨着排、按自然宽度靠左,右侧留空。
    private var filterBar: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(TodoFilter.allCases, id: \.self) { option in
                    filterButton(option)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
    }

    /// 单个筛选胶囊;选中/未选中是两种不同的具体 PrimitiveButtonStyle 类型,
    /// 不能用三元表达式在 .buttonStyle() 里混用,拆成 @ViewBuilder 两个分支。
    @ViewBuilder
    private func filterButton(_ option: TodoFilter) -> some View {
        if filter == option {
            Button(option.title) {
                withAnimation(.snappy) { filter = option }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(option.title) {
                withAnimation(.snappy) { filter = option }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.semibold))
        }
    }

    /// 按天分组的 Section 标题(全部/已完成共用):今天/明天/昨天,其余按
    /// "月日 周X" 格式,跨过去/今天/未来都覆盖到。
    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day().weekday())
    }

    // MARK: - 区块

    /// 完成后的实际耗时轻量条(智能采样,队列化;选择/跳过后出下一条)。
    private func askDurationSection(_ ask: (title: String, planned: Int)) -> some View {
        Section {
            AskDurationBanner(
                title: ask.title, planned: ask.planned,
                onPick: { _ in popAskDuration() },
                onSkip: { popAskDuration() })
        }
    }

    /// "今天"筛选态:今天该做的 + 全部到期未处理的(含遗漏的过去几天,冒泡到
    /// 这里、时间标红,见 effectiveDay/taskRow),不再单独有一个"到期提醒"区块。
    private var todaySection: some View {
        Section {
            if pending.isEmpty {
                ContentUnavailableView {
                    Label("暂无待办事项", systemImage: "checkmark.circle")
                } description: {
                    Text("跟 AI 说一句话就能新建,比如「明天下午3点开会」。")
                } actions: {
                    Button("开始添加") { sheet = .agent(prefill: nil) }
                        .glassProminentButton()
                }
            } else if todayTasks.isEmpty {
                Text("今天暂无待办").foregroundStyle(.secondary)
            }
            ForEach(todayTasks) { task in
                TaskRowView(task: task, now: now,
                            onEdit: { sheet = .edit(task, nil) },
                            onAskDuration: { title, planned in
                                askDurationQueue.append((title, planned))
                            })
            }
        } header: {
            Text("今天待办")
        }
    }

    /// "未来"筛选态:明天及以后,平铺一个列表(每行自带日期,见 TaskItem.caption)。
    private var futureSection: some View {
        Section {
            if futureTasks.isEmpty {
                Text("没有未来待办").foregroundStyle(.secondary)
            }
            ForEach(futureTasks) { task in
                TaskRowView(task: task, now: now,
                            onEdit: { sheet = .edit(task, nil) },
                            onAskDuration: { title, planned in
                                askDurationQueue.append((title, planned))
                            })
            }
        } header: {
            Text("未来待办")
        }
    }

    /// "全部"筛选态:全部待办(含到期未处理的)按天分 Section,上下滑动浏览。
    @ViewBuilder
    private var allSections: some View {
        if pending.isEmpty {
            Section {
                Text("没有待办").foregroundStyle(.secondary)
            } header: {
                Text("全部待办")
            }
        } else {
            ForEach(allGroupedByDay, id: \.date) { group in
                Section(dayLabel(group.date)) {
                    ForEach(group.tasks) { task in
                        TaskRowView(task: task, now: now,
                                    onEdit: { sheet = .edit(task, nil) },
                                    onAskDuration: { title, planned in
                                        askDurationQueue.append((title, planned))
                                    })
                    }
                }
            }
        }
    }

    /// "已完成"筛选态:与"全部"同一套按天分 Section 的范式,周洞察卡片放最前面。
    @ViewBuilder
    private var doneSections: some View {
        if insightEnabled, let insight {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本周洞察")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(insight, systemImage: "sparkles")
                        .font(.subheadline)
                }
                .padding(.vertical, 2)
            }
        }
        if doneTasks.isEmpty {
            Section {
                ContentUnavailableView("还没有完成的事项", systemImage: "tray")
            } header: {
                Text("已完成")
            }
        } else {
            ForEach(doneGroupedByDay, id: \.date) { group in
                Section(dayLabel(group.date)) {
                    ForEach(group.tasks) { task in
                        doneRow(task)
                    }
                }
            }
        }
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
