import SwiftUI
import SwiftData
import LodoCore

/// 「总览」页:一组和时间相关的 widget 模块(今天/接下来/到期提醒/今天任务/
/// 今日日程/倒数日/今日例行/AI 处理建议/今天的记忆/健康),两列网格——小卡
/// 半宽、大卡整宽。顺序、显示与否、大小由用户点右上角「编辑」就地调整
/// (参考 iOS 主屏幕编辑小组件,见 OverviewEditing.swift)
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
    @Environment(\.itemNavigator) private var navigator
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query(sort: [SortDescriptor(\AIRoutineRun.createdAt, order: .reverse)])
    private var routineRuns: [AIRoutineRun]
    /// 最近 5 周完成的(本周完成/近 4 周热力格子/今天完成几件都只看这一段;
    /// 重复事项完成一次也会插一条 done 历史,正好算进来)。窗口在 init 时定,
    /// 比要用的 4 周多留一周,页面跨几天不重建也够用——不再把全部历史都捞出来。
    @Query private var doneTasks: [TaskItem]
    @Query(sort: \TravelTrip.startDate) private var trips: [TravelTrip]
    @Query(sort: \AIRoutine.createdAt) private var routines: [AIRoutine]
    /// 「倒数日」页里建的,汇进总览的倒数日模块。
    @Query private var countdownEvents: [CountdownEvent]
    @Environment(\.scenePhase) private var scenePhase
    /// widget 布局(顺序/显示/大小),右上角「编辑」就地改。
    @AppStorage(AppSettings.overviewLayoutKey) private var layoutRaw = ""
    @State private var isEditingLayout = false
    @State private var showWidgetGallery = false
    /// 编辑态下正在被拖动的那张卡。
    @State private var draggingWidget: OverviewWidgetKind?
    /// 今明两天的系统日程,「接下来」和「今日日程」共用。
    @State private var upcomingEvents: [CalendarEvent] = []
    #if DEBUG
    @State private var demoEvents = false
    #endif

    /// 每分钟刷新一次(「接下来」的倒计时要走),回前台/下拉时也刷新。
    @State private var now = Date()
    @State private var editingTask: TaskItem?
    /// 在总览里点圆圈完成的,键是卡片上划掉的那一行(一次性事项本身 / 重复事项插入的历史)。
    @State private var completionUndos: [UUID: TaskActions.CompletionUndo] = [:]
    @State private var suggestion: OverviewAIText = .loading
    @State private var memorySummary: OverviewAIText = .loading
    @State private var newsItems: [NewsDigest.Item] = []
    @State private var newsPlaceholder = "正在整理订阅要闻…"
    @State private var newsLoading = false
    @State private var healthTip: OverviewAIText = .loading
    /// 圆环/步数图用的最近 7 天健康汇总;nil = 健康开关关着(那时一次 HealthKit 都不读)。
    @State private var healthReport: HealthReport?
    /// 空气质量模块的数据;没开或没取到时为 nil。
    @State private var airReport: AirQualityReport? = AirQualityStore.cached()
    @State private var weather: WeatherReport? = WeatherStore.cached()
    @State private var airLoading = false
    @State private var airFailure: AirQualityStore.Failure?
    @AppStorage(AppSettings.airQualityEnabledKey) private var airQualityEnabled = false
    /// 通知"改期"按钮交接的改期候选(横幅展示,与 TaskRowView 内部滑动触发的
    /// 改期各自独立——见 OverviewView+Reschedule.swift 顶部注释)。
    @State var notificationReschedule: (task: TaskItem, candidates: [(label: String, date: Date)])?
    @State var notificationRescheduleLoading: UUID?
    @State var rescheduleError: String?
    @State var notificationRescheduleTask: Task<Void, Never>?

    /// UserDefaults 里存 `<key>Stamp` / `<key>Text` 两项(见 cachedAIText)。
    private static let suggestionKey = "overviewSuggestion"
    private static let memoryKey = "overviewMemorySummary"
    private static let healthKey = "overviewHealth"

    init(rescheduleRequestUUID: Binding<String?>) {
        _rescheduleRequestUUID = rescheduleRequestUUID
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: .now)) ?? .distantPast
        _doneTasks = Query(filter: #Predicate<TaskItem> {
            $0.statusRaw == "done" && ($0.doneAt ?? cutoff) > cutoff
        }, sort: [SortDescriptor(\TaskItem.doneAt, order: .reverse)])
    }

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
        // 这份清单会发给 AI 总结;「AI 与资产隔离」开着时资产不算在里面。
        memoryItems.filter {
            Calendar.current.isDateInToday($0.createdAt) && !($0.isAsset && AppSettings.assetsAIIsolated)
        }
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
                                editableWidget(item)
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
                            Text("点右上角的「编辑」,再点「+」添加小组件。")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.lodoAware(.snappy), value: layout)
                .animation(.lodoAware(.snappy), value: isEditingLayout)
            }
            // 拖到卡片之间的缝里松手也要清掉"正在拖"。
            .onDrop(of: [.text], delegate: OverviewDragReset(dragging: $draggingWidget))
            .background(pageBackground.ignoresSafeArea())
            .pageTitle("总览")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .toolbar {
                if !(chrome?.hidesChrome ?? false) {
                    if isEditingLayout {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showWidgetGallery = true
                            } label: {
                                Label("添加小组件", systemImage: "plus")
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { setEditing(false) }
                                .fontWeight(.semibold)
                        }
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            Button("编辑") { setEditing(true) }
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
            .sheet(isPresented: $showWidgetGallery) {
                OverviewWidgetGallery(layout: layoutBinding)
                    .presentationDetents([.medium, .large])
            }
            // 切去别的页面时退出编辑态,回来不该还在抖。
            .onChange(of: chrome?.hidesChrome ?? false) { _, hidden in
                if hidden { setEditing(false) }
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
                Task { await loadHealthReport(); await loadNews() }
            }
            // 页面一直开着过了 0 点:日历要补上新的"明天",健康圆环要取今天的数。
            // AI 那几段的 task id 里带着日期,自己会重新要。
            .onChange(of: dayStamp) { _, _ in
                reloadEvents()
                Task { await loadHealthReport() }
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
            .task(id: "\(dayStamp)-\(isVisible(.news))") {
                await loadNews()
            }
            // 空气质量:每半小时一档(缓存本身 30 分钟内不重复请求),模块不显示时不取。
            .task(id: "\(Int(now.timeIntervalSince1970 / 1800))-\(airQualityEnabled)-\(isVisible(.airQuality))") {
                await loadAirQuality()
            }
            // AI 那几段按"当天 + 输入内容"取:完成了一件、新收藏了一条,指纹变了就重新要;
            // 等 1.5 秒再发,连着点完成几件只要一次。
            .task(id: "\(dayStamp)|\(suggestionFingerprint)|\(isVisible(.suggestion))") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await loadSuggestion()
            }
            .task(id: "\(dayStamp)|\(memoryFingerprint)|\(isVisible(.memories))") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await loadMemorySummary()
            }
            .task(id: "\(dayStamp)|\(isVisible(.health))") {
                await loadHealthTip()
            }
            .task(id: "\(dayStamp)|\(healthWidgetsVisible)") {
                await loadHealthReport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newsDigestsUpdated)) { _ in
                Task { await loadNews() }
            }
            .task {
                now = Date()
            }
            .refreshable {
                now = Date()
                reloadEvents()
                // 互不依赖,一起发;下拉的转圈等最慢的那个。
                async let news: Void = loadNews(force: true)
                async let health: Void = loadHealthReport()
                async let air: Void = loadAirQuality(force: true)
                async let suggestion: Void = loadSuggestion(force: true)
                async let memories: Void = loadMemorySummary(force: true)
                async let tip: Void = loadHealthTip(force: true)
                _ = await (news, health, air, suggestion, memories, tip)
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
        // 同 iOS systemGroupedBackground:浅灰页面上放白卡片。
        Color.lodoDynamic(light: 0xF2F2F7, dark: 0x1C1C1E)
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
    }

    private func bannerCard(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OverviewWidgetCard<EmptyView>.cardFill,
                        in: RoundedRectangle(cornerRadius: DesignMetrics.widgetRadius, style: .continuous))
    }

    // MARK: - widget

    private func editableWidget(_ item: OverviewWidgetItem) -> some View {
        OverviewEditableWidget(
            item: item,
            seed: layout.items.firstIndex { $0.kind == item.kind } ?? 0,
            isEditing: isEditingLayout,
            dragging: $draggingWidget,
            onRemove: {
                Haptics.impact(.light)
                updateLayout { $0.setVisible(false, for: item.kind) }
            },
            onResize: { size in updateLayout { $0.setSize(size, for: item.kind) } },
            onMove: { dragged, target in updateLayout { $0.move(dragged, to: target) } }
        ) {
            widget(item)
        }
    }

    private func updateLayout(_ change: (inout OverviewLayout) -> Void) {
        var next = layout
        change(&next)
        withAnimation(.lodoAware(.snappy)) { layoutRaw = next.encoded() }
    }

    private func setEditing(_ editing: Bool) {
        guard editing != isEditingLayout else { return }
        if editing { Haptics.impact(.medium) }
        draggingWidget = nil
        withAnimation(.lodoAware(.snappy)) { isEditingLayout = editing }
    }

    @ViewBuilder
    private func widget(_ item: OverviewWidgetItem) -> some View {
        switch item.kind {
        case .news:
            OverviewWidgetCard(kind: .news, trailing: "AI · RSS", action: { chrome?.go(.news) }) {
                if newsItems.isEmpty {
                    OverviewEmptyText(text: LocalizedStringKey(newsPlaceholder))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(newsItems.prefix(3).enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
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
                                completed: doneToday, now: now, line: taskLine,
                                doneLine: doneTaskLine) {
                chrome?.go(.todo)
            }
        case .agenda:
            OverviewAgendaWidget(size: item.size, events: calendarConnected ? todayEvents : nil,
                                 taskTimes: todayTaskTimes, now: now) { chrome?.go(.calendar) }
        case .backlog:
            let backlog = OverviewBacklog.build(remindAts: pending.map(\.remindAt), now: now)
            OverviewBacklogWidget(size: item.size, backlog: backlog,
                                  oldest: backlog.oldestIndex.map { pending[$0] }) { chrome?.go(.todo) }
        case .trip:
            let trip = tripStatus
            OverviewTripWidget(size: item.size, trip: trip.map { tripCandidates[$0.tripIndex] },
                               status: trip, now: now) {
                if let trip {
                    let uuid = tripCandidates[trip.tripIndex].uuid
                    if let navigator { navigator.open(.trip(uuid)) } else { chrome?.go(.travel) }
                }
            }
        case .recovery:
            OverviewRecoveryWidget(size: item.size, report: healthReport, now: now) { chrome?.go(.health) }
        case .routineStatus:
            OverviewRoutineStatusWidget(size: item.size, status: routineStatus, now: now)
        case .countdown:
            OverviewCountdownWidget(size: item.size, entries: countdownEntries, now: now,
                                    action: { chrome?.go(.countdown) })
        case .countUp:
            OverviewCountUpWidget(size: item.size,
                                  items: CountdownPlan.countUps(countdownEvents.map(\.entry), now: now),
                                  now: now, action: { chrome?.go(.countdown) })
        case .routines:
            OverviewRoutinesWidget(runs: todayRoutineRuns)
        case .suggestion:
            OverviewTextWidget(kind: .suggestion, state: suggestion)
        case .memories:
            OverviewTextWidget(kind: .memories, state: memorySummary)
        case .health:
            // 点一下去健康页看完整趋势;跨页跳转走 sidebarChrome.go。
            OverviewTextWidget(kind: .health, state: healthTip, action: { chrome?.go(.health) })
        case .activityRings:
            OverviewActivityRingsWidget(size: item.size, report: healthReport, now: now) {
                chrome?.go(.health)
            }
        case .taskProgress:
            let plan = OverviewCharts.todayPlan(doneToday: doneTodayCount,
                                                pendingRemindAts: pending.map(\.remindAt), now: now)
            OverviewTaskProgressWidget(size: item.size, done: plan.done,
                                       remaining: plan.remaining, now: now) {
                chrome?.go(.todo)
            }
        case .weeklyDone:
            let doneDates = doneTasks.compactMap(\.doneAt)
            OverviewWeeklyDoneWidget(
                size: item.size,
                days: OverviewCharts.recentWeeks(doneDates: doneDates, weeks: 4, now: now),
                comparison: OverviewCharts.weekToDate(doneDates: doneDates, now: now)) {
                chrome?.go(.todo)
            }
        case .airQuality:
            OverviewAirQualityWidget(size: item.size, report: airReport, weather: weather,
                                     enabled: airQualityEnabled, loading: airLoading,
                                     failure: airFailure, now: now) { chrome?.go(.health) }
        case .stepsTrend:
            OverviewStepsTrendWidget(
                size: item.size,
                values: healthReport.map { report in
                    OverviewCharts.recentDays(
                        points: report.series(.steps)?.points.map { ($0.date, $0.value) } ?? [],
                        now: now)
                }) {
                chrome?.go(.health)
            }
        }
    }

    /// 与新闻页共用当天的 AI 简报,前三条已按重要程度排序、合并同一事件。
    private func loadNews(force: Bool = false) async {
        guard layout.items.contains(where: { $0.kind == .news && $0.isVisible }),
              !newsLoading else { return }
        guard NewsStore.feeds(in: context).contains(where: \.enabled) else {
            newsItems = []
            newsPlaceholder = "订阅 RSS 后显示三条要闻"
            return
        }
        let cached = NewsStore.cachedDigest()
        newsItems = Array((cached?.digest.items ?? []).prefix(3))
        newsPlaceholder = "最近 24 小时暂无可整理的要闻"
        if !force, cached != nil { return }
        guard DeepSeekClient.isConfigured else {
            newsPlaceholder = "配置 AI 后显示三条要闻"
            return
        }
        newsLoading = true
        newsPlaceholder = "正在整理订阅要闻…"
        defer { newsLoading = false }
        await NewsStore.refreshAll(context: context, force: force)
        guard !Task.isCancelled else { return }
        do {
            let digest = try await NewsStore.generateDigest(language: AppSettings.language, context: context)
            try Task.checkCancellation()
            newsItems = Array((digest?.items ?? []).prefix(3))
            newsPlaceholder = "最近 24 小时暂无可整理的要闻"
        } catch {
            newsPlaceholder = "暂时无法整理要闻,请到新闻页重试"
        }
    }

    /// 健康开关关着时不读 HealthKit(同 loadHealthTip 的隐私口径),圆环/步数图显示引导。
    /// 天气和空气质量是同一次刷新里的两个独立请求:哪个失败都不拖累另一个,
    /// 所以结果不管成败都把两份缓存各自读回来;失败原因单独记着,卡片上如实说。
    private func loadAirQuality(force: Bool = false) async {
        guard airQualityEnabled else {
            airReport = nil
            weather = nil
            airFailure = nil
            return
        }
        guard isVisible(.airQuality), !airLoading else { return }
        airLoading = true
        defer { airLoading = false }
        switch await AirQualityStore.refresh(force: force) {
        case .success(let report):
            airReport = report
            airFailure = nil
        case .failure(let error):
            airReport = AirQualityStore.cached()
            airFailure = error.failure
        }
        weather = WeatherStore.cached()
    }

    private func loadHealthReport() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-overview-widgets") {
            healthReport = Self.demoHealthReport()
            return
        }
        #endif
        guard AppSettings.healthEnabled else {
            healthReport = nil
            return
        }
        // 用到健康数据的模块都没显示时不读 HealthKit。
        guard healthWidgetsVisible else { return }
        healthReport = await HealthKitBridge.report(days: 7)
    }

    private func taskLine(_ task: TaskItem) -> OverviewTaskLine {
        OverviewTaskLine(
            task: task, now: now,
            onToggle: {
                Haptics.success()
                withAnimation(.lodoAware(.snappy)) {
                    let undo = TaskActions.completeUndoably(task, context: context)
                    // 一次性事项自己变成 done;重复事项顺延,卡片上划掉的是插进来的那条历史。
                    completionUndos[undo.historyUUID ?? undo.before.uuid] = undo
                }
            },
            onEdit: { editingTask = task },
            onSnooze: { TaskActions.snooze(task, context: context) },
            onDelete: { TaskActions.delete(task, context: context) })
    }

    /// 今天完成的那一行:点圆圈撤销。这次打开总览时在这里完成的,用完成前的快照
    /// 原样改回(重复事项连那条历史一起删);别处完成的没有快照,按已完成列表的
    /// 「恢复为待办」处理。
    private func doneTaskLine(_ task: TaskItem) -> OverviewTaskLine {
        OverviewTaskLine(
            task: task, now: now, isDone: true,
            onToggle: {
                Haptics.impact(.light)
                withAnimation(.lodoAware(.snappy)) {
                    if let undo = completionUndos.removeValue(forKey: task.uuid) {
                        TaskActions.undo(undo, context: context)
                    } else {
                        TaskActions.restore(task, context: context)
                    }
                }
            },
            onEdit: {}, onSnooze: {}, onDelete: {})
    }

    // MARK: - 数据

    /// 布局 JSON 一次 body 里要用好几回;按原串缓存解码结果,串没变就不再解。
    private var layout: OverviewLayout { Self.layoutMemo.layout(for: layoutRaw) }
    private static let layoutMemo = OverviewLayoutMemo()

    private func isVisible(_ kind: OverviewWidgetKind) -> Bool {
        layout.items.contains { $0.kind == kind && $0.isVisible }
    }

    private var healthWidgetsVisible: Bool {
        [.activityRings, .stepsTrend, .recovery].contains(where: isVisible)
    }

    private var dayStamp: String { Self.dayFormatter.string(from: now) }

    /// 今天还没完成、有具体时刻的任务(今日时间轴上的点)。
    private var todayTaskTimes: [Date] {
        pending.filter { !$0.allDay && Calendar.current.isDate($0.nextRemindAt, inSameDayAs: now) }
            .map(\.nextRemindAt)
    }

    /// 处理建议的输入指纹:用原定时间而不是下一次响铃——到期的事每 15 分钟顺延一次
    /// nextRemindAt,按它算的话建议会跟着每 15 分钟重新要一遍。
    private var suggestionFingerprint: String {
        OverviewCharts.fingerprint((due + todayUpcoming).map {
            "\($0.uuid)|\($0.title)|\($0.remindAt.timeIntervalSince1970)"
        })
    }

    private var memoryFingerprint: String {
        OverviewCharts.fingerprint(todayMemories.map { "\($0.uuid)|\($0.title)|\($0.summary)" })
    }

    /// 旅行中模块只看还没结束、60 天内出发的那几次,行程项也只为它们取。
    private var tripCandidates: [TravelTrip] {
        let today = Calendar.current.startOfDay(for: now)
        let horizon = today.addingTimeInterval(61 * 86400)
        return trips.filter { Calendar.current.startOfDay(for: $0.endDate) >= today && $0.startDate < horizon }
    }

    private var tripStatus: OverviewTripStatus? {
        let candidates = tripCandidates
        return OverviewTripStatus.build(
            trips: candidates.map { ($0.startDate, $0.endDate) },
            entries: candidates.map { TravelStore.entries(for: $0.uuid, from: memoryItems) },
            now: now)
    }

    private var routineStatus: OverviewRoutineStatus {
        let cutoff = Calendar.current.startOfDay(for: now).addingTimeInterval(-7 * 86400)
        return OverviewRoutineStatus.build(
            routines: routines.map { ($0.uuid, $0.name, $0.enabled, $0.nextRun(after: now)) },
            runs: routineRuns.prefix { $0.createdAt >= cutoff }.map { ($0.routineUUID, $0.failed, $0.createdAt) },
            now: now)
    }

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

    private var doneToday: [TaskItem] {
        doneTasks.filter { $0.doneAt.map(Calendar.current.isDateInToday) ?? false }
    }

    private var doneTodayCount: Int { doneToday.count }

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
            countdowns: countdownEvents.map(\.entry),
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
    /// 截图用的样板健康数据:最近 7 天,今天走到一半。
    private static func demoHealthReport() -> HealthReport {
        let today = Calendar.current.startOfDay(for: Date())
        func series(_ kind: HealthMetricKind, _ values: [Double]) -> HealthSeries {
            HealthSeries(kind: kind, points: values.enumerated().map { index, value in
                HealthDailyPoint(date: today.addingTimeInterval(Double(index - values.count + 1) * 86400),
                                 value: value)
            })
        }
        return HealthReport(series: [
            series(.steps, [6200, 9100, 7400, 10300, 5600, 8800, 5200]),
            series(.activeEnergy, [420, 610, 380, 560, 300, 520, 360]),
            series(.exerciseMinutes, [25, 42, 18, 35, 10, 31, 22]),
            series(.sleepHours, [7.1, 6.4, 7.8, 5.9, 6.8, 8.2, 6.6]),
            series(.restingHeartRate, [62, 64, 60, 66, 63, 59, 61]),
            series(.hrv, [42, 38, 47, 35, 41, 50, 44]),
        ], rangeDays: 7)
    }

    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        // 截图:在总览里点掉今天的前两件(验证划掉显示),加 `--demo-overview-undo` 再撤销第一件。
        if args.contains("--demo-overview-complete") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                for task in todayRemaining.prefix(2) { taskLine(task).onToggle() }
                if args.contains("--demo-overview-undo") {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if let first = doneToday.first(where: { completionUndos[$0.uuid] != nil }) {
                        doneTaskLine(first).onToggle()
                    }
                }
            }
        }
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
            isEditingLayout = true
        }
        if args.contains("--demo-overview-widget-gallery") {
            isEditingLayout = true
            showWidgetGallery = true
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

    /// AI 那几段的缓存:按"当天 + 输入指纹"认,只在成功时写——离线/请求失败不会把
    /// 当天"钉死"成空;任务完成了、新收藏了,指纹对不上就重新要一份。
    private func cachedAIText(_ key: String, stamp: String) -> String? {
        guard UserDefaults.standard.string(forKey: key + "Stamp") == stamp else { return nil }
        return UserDefaults.standard.string(forKey: key + "Text")
    }

    private func storeAIText(_ text: String, key: String, stamp: String) {
        UserDefaults.standard.set(stamp, forKey: key + "Stamp")
        UserDefaults.standard.set(text, forKey: key + "Text")
    }

    #if DEBUG
    /// 截图用:不发请求,三段 AI 直接摆样板文字。
    private var demoAI: Bool { ProcessInfo.processInfo.arguments.contains("--demo-overview-ai") }
    #endif

    private func loadSuggestion(force: Bool = false) async {
        #if DEBUG
        if demoAI {
            suggestion = .text("先处理到期的「团队周会」,再按时间顺序做剩下几件,写周报可以留到最后。")
            return
        }
        #endif
        guard isVisible(.suggestion) else { return }
        guard DeepSeekClient.isConfigured else {
            suggestion = .unavailable("配置 AI 后显示处理建议")
            return
        }
        let items = due + todayUpcoming
        guard !items.isEmpty else {
            suggestion = .empty("今天没有需要处理的任务")
            return
        }
        let stamp = "\(dayStamp)|\(suggestionFingerprint)"
        if !force, let cached = cachedAIText(Self.suggestionKey, stamp: stamp) {
            suggestion = .text(cached)
            return
        }
        // 已经有一段时只在后台换掉,不把卡片闪回"正在整理"。
        if case .text = suggestion {} else { suggestion = .loading }
        let summary = items.filter { !$0.isMedicationReminder }
            .map { "「\($0.title)」\($0.caption)" }.joined(separator: "、")
        guard !summary.isEmpty else {
            suggestion = .empty("今天没有需要处理的任务")
            return
        }
        do {
            let text = try await DeepSeekClient.suggestTodayHandling(summary: summary)
            guard !Task.isCancelled else { return }
            storeAIText(text, key: Self.suggestionKey, stamp: stamp)
            suggestion = .text(text)
        } catch {
            guard !Task.isCancelled else { return }
            if case .text = suggestion {} else { suggestion = .failed }
        }
    }

    /// 健康提示:总开关关着时一个请求都不发(健康数据敏感,不该默认往外送);
    /// 健康数据一天内变化不大,只按天缓存。
    private func loadHealthTip(force: Bool = false) async {
        #if DEBUG
        if demoAI {
            healthTip = .text("这周步数比上周多了两成,静息心率降了 3 次/分;睡眠偏短,今晚早点睡。")
            return
        }
        #endif
        guard isVisible(.health) else { return }
        guard AppSettings.healthEnabled else {
            healthTip = .unavailable("在设置里开启健康分析后显示")
            return
        }
        guard DeepSeekClient.isConfigured else {
            healthTip = .unavailable("配置 AI 后显示健康提示")
            return
        }
        let stamp = dayStamp
        if !force, let cached = cachedAIText(Self.healthKey, stamp: stamp) {
            healthTip = .text(cached)
            return
        }
        if case .text = healthTip {} else { healthTip = .loading }
        let report = await HealthKitBridge.report(days: AppSettings.healthRangeDays)
        guard !report.isEmpty else {
            healthTip = .empty("暂无健康数据")
            return
        }
        do {
            let text = try await DeepSeekClient.suggestTodayHealth(summary: report.promptSummary())
            guard !Task.isCancelled else { return }
            storeAIText(text, key: Self.healthKey, stamp: stamp)
            healthTip = .text(text)
        } catch {
            guard !Task.isCancelled else { return }
            if case .text = healthTip {} else { healthTip = .failed }
        }
    }

    private func loadMemorySummary(force: Bool = false) async {
        #if DEBUG
        if demoAI {
            memorySummary = .text("今天收藏的都是效率类内容,建议这周找时间整理一下笔记。")
            return
        }
        #endif
        guard isVisible(.memories) else { return }
        guard !todayMemories.isEmpty else {
            memorySummary = .empty("今天还没有新收藏")
            return
        }
        guard DeepSeekClient.isConfigured else {
            memorySummary = .unavailable("配置 AI 后显示今天收藏的总结")
            return
        }
        let stamp = "\(dayStamp)|\(memoryFingerprint)"
        if !force, let cached = cachedAIText(Self.memoryKey, stamp: stamp) {
            memorySummary = .text(cached)
            return
        }
        if case .text = memorySummary {} else { memorySummary = .loading }
        let summary = todayMemories.map { "「\($0.title)」\($0.summary)" }.joined(separator: "、")
        do {
            let text = try await DeepSeekClient.summarizeTodayMemories(summary: summary)
            guard !Task.isCancelled else { return }
            storeAIText(text, key: Self.memoryKey, stamp: stamp)
            memorySummary = .text(text)
        } catch {
            guard !Task.isCancelled else { return }
            if case .text = memorySummary {} else { memorySummary = .failed }
        }
    }
}

/// 布局 JSON 的解码缓存(见 `OverviewView.layout`)。
@MainActor
final class OverviewLayoutMemo {
    private var raw: String?
    private var value = OverviewLayout.default

    func layout(for raw: String) -> OverviewLayout {
        if raw != self.raw {
            self.raw = raw
            value = OverviewLayout.decode(raw)
        }
        return value
    }
}
