import SwiftUI
import SwiftData
import LodoCore

/// 「总览」页:一组和时间相关的 widget 模块(今天/接下来/到期提醒/今天任务/
/// 今日日程/倒数日/今日例行/AI 处理建议/今天的记忆/健康),两列网格——小卡
/// 半宽、大卡整宽。顺序、显示与否、大小由用户在右上角「编辑布局」里定
/// (`OverviewLayout`,纯逻辑在 LodoCore,存 `AppSettings.overviewLayoutKey`)。
/// 任务行:点圆圈完成、点行编辑、长按稍等/删除(卡片里没有 List,用不上
/// swipeActions)。AI 那几段按天缓存,见 loadSuggestion/loadMemorySummary。
struct OverviewView: View {
    /// 非 nil 时跳到该事项并自动发起改期请求(通知"改期"按钮交接,见 ContentView)。
    @Binding var rescheduleRequestUUID: String?

    // 以下几个跨 extension 文件(OverviewView+Reschedule)被读写,
    // 不能用 private(Swift 的 private 只对同一文件可见),保持 internal。
    @Environment(\.modelContext) var context
    @Environment(\.sidebarChrome) private var chrome
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query(sort: [SortDescriptor(\AIRoutineRun.createdAt, order: .reverse)])
    private var routineRuns: [AIRoutineRun]
    /// 今天完成了几件(重复事项完成一次也会插一条 done 历史,正好算进来)。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "done" },
           sort: [SortDescriptor(\TaskItem.doneAt, order: .reverse)])
    private var doneTasks: [TaskItem]
    @Query(sort: \TravelTrip.startDate) private var trips: [TravelTrip]
    @Environment(\.scenePhase) private var scenePhase
    /// widget 布局(顺序/显示/大小),右上角「编辑布局」改。
    @AppStorage(AppSettings.overviewLayoutKey) private var layoutRaw = ""
    @State private var showLayoutEditor = false
    /// 今明两天的系统日程,「接下来」和「今日日程」共用。
    @State private var upcomingEvents: [CalendarEvent] = []
    #if DEBUG
    @State private var demoEvents = false
    #endif

    /// 每分钟刷新一次(「接下来」的倒计时要走),回前台/下拉时也刷新。
    @State private var now = Date()
    @State private var editingTask: TaskItem?
    @State private var askDurationQueue: [(title: String, planned: Int)] = []
    @State private var suggestion: String?
    @State private var memorySummary: String?
    @State private var healthTip: String?
    /// 通知"改期"按钮交接的改期候选(横幅展示,与 TaskRowView 内部滑动触发的
    /// 改期各自独立——见 OverviewView+Reschedule.swift 顶部注释)。
    @State var notificationReschedule: (task: TaskItem, candidates: [(label: String, date: Date)])?
    @State var notificationRescheduleLoading: UUID?
    @State var rescheduleError: String?
    @State var notificationRescheduleTask: Task<Void, Never>?

    private static let suggestionDayKey = "overviewSuggestionDay"
    private static let suggestionTextKey = "overviewSuggestionText"
    private static let memorySummaryDayKey = "overviewMemorySummaryDay"
    private static let memorySummaryTextKey = "overviewMemorySummaryText"
    private static let healthDayKey = "overviewHealthDay"
    private static let healthTextKey = "overviewHealthText"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var due: [TaskItem] { pending.filter { $0.nextRemindAt <= now } }
    private var todayUpcoming: [TaskItem] {
        pending.filter { $0.nextRemindAt > now && Calendar.current.isDateInToday($0.nextRemindAt) }
    }
    private var todayMemories: [MemoryItem] {
        memoryItems.filter { Calendar.current.isDateInToday($0.createdAt) }
    }
    /// 今天各条定时任务最新的一次成功结果(同一条任务当天跑了多次只留最新的,
    /// 失败的不展示——总览是"看今天怎么样",报错留在设置里的任务详情看)。
    private var todayRoutineRuns: [AIRoutineRun] {
        var seen = Set<UUID>()
        return routineRuns.filter { run in
            guard !run.failed, Calendar.current.isDateInToday(run.createdAt),
                  !seen.contains(run.routineUUID) else { return false }
            seen.insert(run.routineUUID)
            return true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    banners
                    ForEach(Array(layout.rows().enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { item in
                                widget(item)
                                    .frame(maxWidth: .infinity)
                            }
                            // 独占半行的小卡:右边留空,不拉成整宽(用户选的是小卡)。
                            if row.count == 1, row[0].size == .small {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                        // 并排的两张小卡等高(内容多的那张决定),看上去才是一排。
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if layout.rows().isEmpty {
                        ContentUnavailableView {
                            Label("没有显示的模块", systemImage: "square.grid.2x2")
                        } description: {
                            Text("点右上角的按钮选择要显示的模块。")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.lodoAware(.snappy), value: layout)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("总览")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .toolbar {
                if !(chrome?.hidesChrome ?? false) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showLayoutEditor = true
                        } label: {
                            Label("编辑布局", systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            .askBar(focus: .overview)
            .sheet(item: $editingTask) { task in
                TaskEditView(existing: task, parsed: nil, attachment: task.attachment) {
                    TaskActions.apply($0, to: task, context: context)
                }
            }
            .sheet(isPresented: $showLayoutEditor) {
                OverviewLayoutEditor(layout: layoutBinding)
                    .presentationDetents([.medium, .large])
            }
            .alert("改期失败", isPresented: Binding(
                get: { rescheduleError != nil },
                set: { if !$0 { rescheduleError = nil } }
            )) {
                Button("好", role: .cancel) { rescheduleError = nil }
            } message: {
                Text(rescheduleError ?? "")
            }
            .onChange(of: rescheduleRequestUUID) { _, uuid in
                consumeReschedule(uuid)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                now = Date()
                reloadEvents()
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                reloadEvents()
            }
            #endif
            // "接下来"的倒计时要跟着走;一分钟一跳足够(卡片上最细只到分钟)。
            .task(id: now) {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                now = Date()
            }
            .onAppear {
                consumeReschedule(rescheduleRequestUUID)
                reloadEvents()
                #if DEBUG
                applyDemoArguments()
                #endif
            }
            .task {
                now = Date()
                await loadSuggestion()
                await loadMemorySummary()
                await loadHealthTip()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-overview-ai") {
                    suggestion = "先处理到期的「团队周会」,再按时间顺序做剩下几件,写周报可以留到最后。"
                    memorySummary = "今天收藏的都是效率类内容,建议这周找时间整理一下笔记。"
                    healthTip = "这周步数比上周多了两成,静息心率降了 3 次/分;睡眠偏短,今晚早点睡。"
                }
                #endif
            }
            .refreshable {
                now = Date()
                reloadEvents()
                await loadSuggestion(force: true)
                await loadMemorySummary(force: true)
                await loadHealthTip(force: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    // MARK: - 顶部横幅(改期候选 / 实际耗时)

    @ViewBuilder
    private var banners: some View {
        if let notificationReschedule {
            bannerCard { notificationRescheduleBanner(notificationReschedule) }
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if notificationRescheduleLoading != nil {
            bannerCard {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在获取改期建议…").foregroundStyle(.secondary)
                }
            }
        }
        if let ask = askDurationQueue.first {
            bannerCard {
                AskDurationBanner(
                    title: ask.title, planned: ask.planned,
                    onPick: { _ in popAskDuration() },
                    onSkip: { popAskDuration() })
            }
        }
    }

    private func bannerCard(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OverviewWidgetCard<EmptyView>.cardFill,
                        in: RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
    }

    // MARK: - widget

    @ViewBuilder
    private func widget(_ item: OverviewWidgetItem) -> some View {
        switch item.kind {
        case .clock:
            OverviewClockWidget()
        case .nextUp:
            OverviewNextUpWidget(size: item.size, items: upcoming, now: now) {
                chrome?.go(upcomingIsEvent ? .calendar : .todo)
            }
        case .due:
            OverviewDueWidget(tasks: due, now: now, line: taskLine) { chrome?.go(.todo) }
        case .today:
            OverviewTodayWidget(size: item.size, remaining: todayRemaining,
                                doneCount: doneTodayCount, now: now, line: taskLine) {
                chrome?.go(.todo)
            }
        case .agenda:
            OverviewAgendaWidget(size: item.size, events: calendarConnected ? todayEvents : nil,
                                 now: now) { chrome?.go(.calendar) }
        case .countdown:
            OverviewCountdownWidget(size: item.size, entries: countdownEntries, now: now)
        case .routines:
            OverviewRoutinesWidget(runs: todayRoutineRuns)
        case .suggestion:
            OverviewTextWidget(kind: .suggestion, text: suggestion,
                               placeholder: DeepSeekClient.isConfigured ? "今天没有需要处理的任务" : "配置 AI 后显示处理建议")
        case .memories:
            OverviewTextWidget(kind: .memories, text: memorySummary,
                               placeholder: todayMemories.isEmpty ? "今天还没有新收藏" : "正在整理今天的收藏…")
        case .health:
            // 点一下去健康页看完整趋势;跨页跳转走 sidebarChrome.go。
            OverviewTextWidget(kind: .health, text: healthTip,
                               placeholder: AppSettings.healthEnabled ? "暂无健康数据" : "在设置里开启健康分析后显示",
                               action: { chrome?.go(.health) })
        }
    }

    private func taskLine(_ task: TaskItem) -> OverviewTaskLine {
        OverviewTaskLine(
            task: task, now: now,
            onComplete: {
                withAnimation(.lodoAware(.snappy)) {
                    if let ask = TaskActions.complete(task, context: context) {
                        askDurationQueue.append(ask)
                    }
                }
            },
            onEdit: { editingTask = task },
            onSnooze: { TaskActions.snooze(task, context: context) },
            onDelete: { TaskActions.delete(task, context: context) })
    }

    // MARK: - 数据

    private var layout: OverviewLayout { OverviewLayout.decode(layoutRaw) }

    private var layoutBinding: Binding<OverviewLayout> {
        Binding(get: { layout }, set: { layoutRaw = $0.encoded() })
    }

    private var calendarConnected: Bool {
        #if DEBUG
        if demoEvents { return true }
        #endif
        return AppSettings.calendarEnabled && CalendarBridge.isAuthorized
    }

    /// 今天剩下的:到期未处理的 + 今天之内还没到时间的。
    private var todayRemaining: [TaskItem] {
        pending.filter { $0.nextRemindAt <= now || Calendar.current.isDateInToday($0.nextRemindAt) }
    }

    private var doneTodayCount: Int {
        doneTasks.filter { $0.doneAt.map(Calendar.current.isDateInToday) ?? false }.count
    }

    private var todayEvents: [CalendarEvent] {
        CalendarViewPlan.events(upcomingEvents, on: now)
    }

    /// 接下来:还没到时间的任务 + 还没开始的日程(不含全天),取最近的几件。
    private var upcoming: [OverviewUpcoming] {
        let tasks = pending.filter { $0.nextRemindAt > now }.prefix(5).map {
            OverviewUpcoming(id: $0.uuid.uuidString, title: $0.title, date: $0.nextRemindAt, isEvent: false)
        }
        let events = upcomingEvents.filter { !$0.isAllDay && $0.start > now }.map {
            OverviewUpcoming(id: $0.occurrenceKey, title: $0.title, date: $0.start, isEvent: true)
        }
        return (tasks + events).sorted { $0.date < $1.date }
    }

    private var upcomingIsEvent: Bool { upcoming.first?.isEvent ?? false }

    private var countdownEntries: [OverviewCountdownEntry] {
        OverviewCountdownEntry.build(
            trips: trips.map { ($0.uuid.uuidString, $0.title, $0.startDate, $0.endDate) },
            birthdays: memoryItems.compactMap { item in
                guard item.isContact, let birthday = item.contactBirthday else { return nil }
                return (item.uuid.uuidString, item.title, birthday)
            },
            now: now)
    }

    /// 今明两天的系统日程("接下来"要能看到明早的会)。没连日历时为空。
    private func reloadEvents() {
        #if DEBUG
        if demoEvents { return }
        #endif
        let today = Calendar.current.startOfDay(for: Date())
        upcomingEvents = CalendarBridge.events(from: today, to: today.addingTimeInterval(2 * 86400))
    }

    #if DEBUG
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-reschedule"), let first = due.first {
            notificationReschedule = (first, [
                (label: "今晚 20:00", date: Date().addingTimeInterval(6 * 3600)),
                (label: "明早 9:00", date: Date().addingTimeInterval(19 * 3600)),
                (label: "周六上午", date: Date().addingTimeInterval(48 * 3600)),
            ])
        }
        // 截图用:塞两条今天的样板日程(只落 @State,不碰真实日历)。
        if args.contains("--demo-overview-widgets") {
            demoEvents = true
            let now = Date()
            upcomingEvents = [
                CalendarEvent(id: "o1", title: "产品评审", start: now.addingTimeInterval(40 * 60),
                              end: now.addingTimeInterval(100 * 60), isAllDay: false, calendarTitle: "工作",
                              calendarColor: CalendarEventColor(red: 0.2, green: 0.47, blue: 0.96)),
                CalendarEvent(id: "o2", title: "接孩子", start: now.addingTimeInterval(5 * 3600),
                              end: now.addingTimeInterval(5.5 * 3600), isAllDay: false, calendarTitle: "家庭",
                              calendarColor: CalendarEventColor(red: 0.85, green: 0.35, blue: 0.62)),
            ]
        }
        if args.contains("--demo-overview-layout-editor") {
            showLayoutEditor = true
        }
    }
    #endif

    /// 通知"改期"按钮交接的改期候选横幅(见 OverviewView+Reschedule.swift)。
    private func notificationRescheduleBanner(
        _ reschedule: (task: TaskItem, candidates: [(label: String, date: Date)])
    ) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("「\(reschedule.task.title)」改期建议").font(.body)
                HorizontalChipRow {
                    ForEach(reschedule.candidates, id: \.label) { candidate in
                        Button(candidate.label) {
                            applyNotificationReschedule(candidate.date)
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                        .tint(.accentColor)
                    }
                    Button {
                        withAnimation(.lodoAware(.snappy)) { notificationReschedule = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .pressable()
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
                    .accessibilityLabel("收起改期候选")
                }
            }
        }
    }

    private func popAskDuration() {
        withAnimation(.lodoAware(.snappy)) {
            if !askDurationQueue.isEmpty { askDurationQueue.removeFirst() }
        }
    }

    /// 按天缓存(参考 TodoListView.loadInsight 按 ISO 周缓存的做法),只在成功
    /// 时写缓存——离线/请求失败不会把当天"钉死"成空。没有待办时不请求,清空展示。
    private func loadSuggestion(force: Bool = false) async {
        guard DeepSeekClient.isConfigured else { return }
        let items = due + todayUpcoming
        guard !items.isEmpty else {
            suggestion = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.suggestionDayKey) == stamp,
           let cached = defaults.string(forKey: Self.suggestionTextKey) {
            suggestion = cached
            return
        }
        let summary = items.map { "「\($0.title)」\($0.caption)" }.joined(separator: "、")
        guard let text = try? await DeepSeekClient.suggestTodayHandling(summary: summary) else { return }
        defaults.set(stamp, forKey: Self.suggestionDayKey)
        defaults.set(text, forKey: Self.suggestionTextKey)
        suggestion = text
    }

    /// 健康提示:总开关关着时一个请求都不发(健康数据敏感,不该默认往外送);
    /// 其余逻辑和 loadSuggestion 一致——按天缓存、只在成功时写缓存。
    private func loadHealthTip(force: Bool = false) async {
        guard AppSettings.healthEnabled, DeepSeekClient.isConfigured else {
            healthTip = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.healthDayKey) == stamp,
           let cached = defaults.string(forKey: Self.healthTextKey) {
            healthTip = cached
            return
        }
        let report = await HealthKitBridge.report(days: AppSettings.healthRangeDays)
        guard !report.isEmpty else {
            healthTip = nil
            return
        }
        guard let text = try? await DeepSeekClient.suggestTodayHealth(
            summary: report.promptSummary()) else { return }
        defaults.set(stamp, forKey: Self.healthDayKey)
        defaults.set(text, forKey: Self.healthTextKey)
        healthTip = text
    }

    private func loadMemorySummary(force: Bool = false) async {
        guard DeepSeekClient.isConfigured else { return }
        guard !todayMemories.isEmpty else {
            memorySummary = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.memorySummaryDayKey) == stamp,
           let cached = defaults.string(forKey: Self.memorySummaryTextKey) {
            memorySummary = cached
            return
        }
        let summary = todayMemories.map { "「\($0.title)」\($0.summary)" }.joined(separator: "、")
        guard let text = try? await DeepSeekClient.summarizeTodayMemories(summary: summary) else { return }
        defaults.set(stamp, forKey: Self.memorySummaryDayKey)
        defaults.set(text, forKey: Self.memorySummaryTextKey)
        memorySummary = text
    }
}
