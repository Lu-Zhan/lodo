import SwiftUI
import SwiftData
import UserNotifications
import LodoCore
#if os(iOS)
import UIKit
#endif

/// 全局 agent 一次解析后的回应形态(AgentView 据此展示)。
enum AgentReply {
    /// 单条新建:route() 已经直接落库(带 lastUndo 快照),AgentView 追加一条
    /// 只读结果卡片,卡片右边一颗 ✕ 兜底——**默认就建**,不再先出一张
    /// Cancel/Confirm 提案卡等用户点确认。和 .updated 同一套写法。
    case created(task: TaskItem, parsed: ParsedTask)
    /// 单条修改:route() 已经直接落库(带 lastUndo 快照),AgentView 追加一条
    /// 只读结果卡片,卡片上带撤销按钮兜底 AI 偶尔解析错的情况。
    case updated(task: TaskItem, parsed: ParsedTask)
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
    /// auto_memorize 是当轮唯一动作时:AI 已经静默记下一条重点事实,
    /// AgentView 据 uuid 展示和 .memorized 同款的结果卡片,但文案不同
    /// ("已自动记录"而不是"已收藏"),不让用户把这两种来源的记忆混为一谈。
    /// 和其他操作混在同一轮时不会走到这个 case——auto_memorize 那时仍然
    /// 静默落库,但没有专属的回执(见 route() 里的处理)。
    case autoMemorized(uuid: UUID)
    /// AI 自动规划了一份行程:AgentView 追加一张规划卡片,用户点「写入行程」
    /// 才真正写进「旅行」页(卡片自己完成写入/撤销,见 AgentTripPlanCard)。
    case tripPlan(TripPlanProposal)
    /// AI 调整了已记下的行程(已经落库):AgentView 追加改动结果卡片,卡片自带撤销。
    case tripEdited(TripEditRecord)
}

/// 记忆条目左滑"转为待办"交接的载荷(见 ContentView)。
struct ConvertToTodoRequest: Equatable {
    var title: String
    var attachment: TaskAttachment
}

/// AI 批量执行(performPendingActions)后留下的撤销记录,一条操作一个 case;
/// 复用备份功能已有的 BackupTask(展平字段 + apply(to:))做"改回原样"的载体,
/// 不用另起一套快照结构。只保留最近一批,执行新的批量操作或用掉一次撤销都会
/// 清空(见 AgentHostView+Routing.swift 的 performUndo)。
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

/// 任务页(原来叫"待办页"——页面名统一成「任务」,事项本身在文案里仍叫待办/
/// 事项):顶部 4 个筛选胶囊(今天/未来/全部/已完成)、到期卡片(完成/稍等,
/// 不受筛选影响永远显示)、按筛选态切换的任务/已完成列表。
struct TodoListView: View {
    /// 非 nil 时弹出"新建事项"表单并预填标题+内容附件(记忆条目"转为待办"交接,
    /// 见 AppShellView)。
    @Binding var convertToTodoRequest: ConvertToTodoRequest?

    // 以下几个跨 extension 文件(TodoListView+CRUD/+Reschedule)被读写,
    // 不能用 private(Swift 的 private 只对同一文件可见),保持 internal。
    @Environment(\.modelContext) var context
    @Environment(\.scenePhase) private var scenePhase
    /// 空态里那颗"开始添加"要把用户送到 AI 页,见 AppShellView.SidebarChrome。
    @Environment(\.sidebarChrome) private var sidebarChrome
    /// 只查未完成事项,已完成事项在待办页底部单独折叠展示。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    /// 已完成事项并入待办页底部,默认折叠展示。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "done" },
           sort: [SortDescriptor(\TaskItem.doneAt, order: .reverse)])
    var doneTasks: [TaskItem]
    /// 待办页里混排展示的定时任务(仅启用的);已停用的只在设置页管理,
    /// 不占待办页的位置。
    @Query(filter: #Predicate<AIRoutine> { $0.enabled },
           sort: \AIRoutine.createdAt)
    private var routines: [AIRoutine]
    /// 用于查"今天跑过没":按天筛选在 `latestRunToday` 里做,这里只按时间倒序,
    /// 取第一条命中的就是最新一条。
    @Query(sort: [SortDescriptor(\AIRoutineRun.createdAt, order: .reverse)])
    private var routineRuns: [AIRoutineRun]

    @AppStorage(AppSettings.insightEnabledKey) private var insightEnabled = true

    @State private var now = Date()
    /// 顶部周条当前显示的那一周(周一零点)。
    @State private var weekStart = CalendarWeek.start(of: Date())
    /// 周条里选中的那天;非 nil 时列表整个切成"那天的日程",筛选胶囊让位。
    @State private var selectedDay: Date?
    /// 当前这一周的系统日历事件(只读)。开关关着或没授权时恒为空数组。
    @State private var weekEvents: [CalendarEvent] = []
    #if DEBUG
    /// --demo-calendar 塞了样板事件:之后的真实查询要让开,不然一进来就被
    /// 空结果覆盖掉(同 HealthView 的 demoOverride,只落在 @State 上)。
    @State private var demoCalendar = false
    #endif
    /// 顶部 4 个筛选胶囊(今天/未来/全部/已完成)当前选中的态。
    @State var filter: TodoFilter = .today
    @State var sheet: SheetMode?
    /// 工具栏"项目视图"菜单的两个入口。
    /// 完成后询问实际耗时的轻量条(队列,连续完成不互相覆盖)。
    @State var askDurationQueue: [(title: String, planned: Int)] = []
    /// 通知权限被拒绝(app 内唯一提醒渠道失效)时提示用户去系统设置开启。
    @State private var notificationsDenied = false
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

    /// 待办 List 动画的聚合触发键,见 body 里的 .animation 用法。
    private struct ListAnimationKey: Equatable {
        let dueUUIDs: [UUID]
        let askTitles: [String]
        let filter: TodoFilter
    }

    enum SheetMode: Identifiable {
        /// attachment 非 nil 时来自记忆条目"转为待办"。
        case create(ParsedTask?, TaskAttachment?)
        /// 编辑事项;agent 路由到修改时带上解析出的新字段预填表单。
        case edit(TaskItem, ParsedTask?)
        /// 待办页里点了一条定时任务行:复用设置页同款的编辑表单。
        case editRoutine(AIRoutine)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let task, _): return task.uuid.uuidString
            case .editRoutine(let routine): return routine.uuid.uuidString
            }
        }
    }

    /// 消费打开期间积压的路由请求(记忆条目"转为待办"可能在表单开着时到达)。
    private func handleSheetDismiss() {
        DispatchQueue.main.async { consumeConvertToTodo(convertToTodoRequest) }
    }

    @ViewBuilder
    private func sheetContent(_ mode: SheetMode) -> some View {
        switch mode {
        case .create(let parsed, let attachment):
            TaskEditView(existing: nil, parsed: parsed, attachment: attachment) {
                saveNew($0, attachment: attachment)
            }
        case .edit(let task, let parsed):
            TaskEditView(existing: task, parsed: parsed, attachment: task.attachment) {
                apply($0, to: task)
            }
        case .editRoutine(let routine):
            RoutineEditView(routine: routine, isNew: false)
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
    // MARK: - 定时任务混排(今天/未来/全部三个筛选态;已完成没有定时任务)

    /// 待办页 List 行的统一形态:定时任务与待办事项混排、按时间排序。
    /// 定时任务只贡献"下一次触发"这一行(不展开每次历史执行),
    /// 与循环待办只显示 nextRemindAt 这一个虚拟行是同一个心智模型。
    private struct TodoRow: Identifiable {
        enum Kind {
            case task(TaskItem)
            case routine(AIRoutine)
        }
        let kind: Kind
        /// 混排排序键:待办用 nextRemindAt,定时任务用 routineSortDate(_:)。
        let sortDate: Date

        var id: AnyHashable {
            switch kind {
            case .task(let task): return task.persistentModelID
            case .routine(let routine): return routine.uuid
            }
        }
    }

    private func taskRow(_ task: TaskItem) -> TodoRow {
        TodoRow(kind: .task(task), sortDate: task.nextRemindAt)
    }

    private func routineRow(_ routine: AIRoutine) -> TodoRow {
        TodoRow(kind: .routine(routine), sortDate: routineSortDate(routine))
    }

    /// 今天已经跑过的最新一条结果(没跑过则 nil),直接显示在行下面。
    private func latestRunToday(_ routine: AIRoutine) -> AIRoutineRun? {
        let uuid = routine.uuid
        return routineRuns.first {
            $0.routineUUID == uuid && Calendar.current.isDate($0.createdAt, inSameDayAs: now)
        }
    }

    /// 定时任务算作哪一天:今天已经跑过就算今天(哪怕下一次计划时间是明天),
    /// 否则按下一次计划触发时间的日期算;两者都没有(没设置有效时间点)就不展示。
    private func effectiveRoutineDay(_ routine: AIRoutine) -> Date? {
        let calendar = Calendar.current
        if latestRunToday(routine) != nil { return calendar.startOfDay(for: now) }
        guard let next = routine.nextRun(after: now) else { return nil }
        return calendar.startOfDay(for: next)
    }

    /// 混排用的排序时间:今天跑过就用运行时刻(保持在它原本的时间位置附近),
    /// 否则用下一次计划触发时间。
    private func routineSortDate(_ routine: AIRoutine) -> Date {
        latestRunToday(routine)?.createdAt ?? routine.nextRun(after: now) ?? .distantFuture
    }

    private var todayRows: [TodoRow] {
        let today = Calendar.current.startOfDay(for: now)
        let taskRows = todayTasks.map(taskRow)
        let routineRows = routines.filter { effectiveRoutineDay($0) == today }.map(routineRow)
        return (taskRows + routineRows).sorted { $0.sortDate < $1.sortDate }
    }

    private var futureRows: [TodoRow] {
        let today = Calendar.current.startOfDay(for: now)
        let taskRows = futureTasks.map(taskRow)
        let routineRows = routines.filter {
            guard let day = effectiveRoutineDay($0) else { return false }
            return day > today
        }.map(routineRow)
        return (taskRows + routineRows).sorted { $0.sortDate < $1.sortDate }
    }

    private var allRowsGroupedByDay: [(date: Date, rows: [TodoRow])] {
        var byDay: [Date: [TodoRow]] = [:]
        for task in pending {
            byDay[effectiveDay(task), default: []].append(taskRow(task))
        }
        for routine in routines {
            guard let day = effectiveRoutineDay(routine) else { continue }
            byDay[day, default: []].append(routineRow(routine))
        }
        return byDay.sorted { $0.key < $1.key }
            .map { (date: $0.key, rows: $0.value.sorted { $0.sortDate < $1.sortDate }) }
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
                if NotificationBudgetState.shared.overflowCount > 0 {
                    notificationOverflowSection
                }
                weekStripSection
                filterBar
                if let ask = askDurationQueue.first {
                    askDurationSection(ask)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // 周条选中了某天就整个让位给那天的日程(任务 + 系统事件);
                // 点任何一个筛选胶囊会把选中取消掉,回到原来四个态。
                if let day = selectedDay {
                    daySection(day)
                } else {
                    switch filter {
                    case .today: todaySection
                    case .future: futureSection
                    case .all: allSections
                    case .done: doneSections
                    }
                }
            }
            // 三路各自独立的触发源(到期列表变化/时长反问队列变化/筛选切换)
            // 合并成一个 Equatable 聚合值,用一个 .animation 修饰符盯——之前
            // 三个 .animation(value:) 各自挂在同一个 List 上,同一时刻多个
            // 修饰符各管一段,冗余且不好看出这几路本质上是"同一份列表的动画"。
            .animation(.lodoAware(.snappy), value: ListAnimationKey(
                dueUUIDs: due.map(\.uuid), askTitles: askDurationQueue.map(\.title), filter: filter))
            .navigationTitle("任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // 右上角现在什么都不放:「并行时间线」和「按项目查看」先后去掉了,
            // 左上角只剩 ☰。项目字段本身还在(表单里能填、AI 也会填),只是
            // 暂时没有按项目浏览的入口(`ProjectListView` 原样留着)。
            .sidebarToolbarButton()
            .askBar(isVisible: !(sidebarChrome?.hidesChrome ?? false))
            // 剩下的三个 sheet 目的地都是叠在待办列表上的卡片型表单
            // (新建/编辑事项、编辑定时任务),iOS 和 macOS 走同一路。
            .sheet(item: $sheet, onDismiss: handleSheetDismiss) { mode in
                sheetContent(mode)
            }
            // 周条那一周的系统日历事件。翻周就重取;开关关着/没授权时
            // CalendarBridge 返回空数组,这里不必自己判断。放 .task 而不是
            // onAppear:翻周要能跟着重跑。
            .task(id: weekStart) { reloadWeekEvents() }
            // 从设置页开完日历开关回来、或别的 app 改过日程之后,回前台重取一次。
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reloadWeekEvents() }
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
            .onAppear {
                // 冷启动时深链可能先于本视图出现,补一次检查
                consumeConvertToTodo(convertToTodoRequest)
                checkNotificationAuthorization()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-ask-duration") {
                    askDurationQueue.append((title: "开周会", planned: 60))
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-seed-data"), pending.isEmpty {
                    seedDemoData()
                }
                // 截图验证用:模拟器里既点不了周条、也没法点系统日历的授权弹窗,
                // 直接塞两条样板事件并选中今天(同 --demo-health 塞样本序列的做法,
                // 只落在 @State 上,不写 UserDefaults、不碰真实日历)。
                if ProcessInfo.processInfo.arguments.contains("--demo-calendar") {
                    demoCalendar = true
                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: Date())
                    weekEvents = [
                        CalendarEvent(id: "demo-1", title: "产品评审",
                                      start: today.addingTimeInterval(10 * 3600),
                                      end: today.addingTimeInterval(11 * 3600),
                                      isAllDay: false, calendarTitle: "工作"),
                        CalendarEvent(id: "demo-2", title: "体检",
                                      start: today, end: today.addingTimeInterval(86400),
                                      isAllDay: true, calendarTitle: "个人"),
                        CalendarEvent(id: "demo-3", title: "牙医",
                                      start: today.addingTimeInterval(86400 + 15 * 3600),
                                      end: today.addingTimeInterval(86400 + 16 * 3600),
                                      isAllDay: false, calendarTitle: "个人"),
                    ]
                    if ProcessInfo.processInfo.arguments.contains("--demo-calendar-day") {
                        selectedDay = today
                    }
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
                    .foregroundStyle(LodoColor.critical)
                #if os(iOS)
                Button("前往系统设置开启") { openNotificationSettings() }
                    .buttonStyle(.bordered)
                #endif
            }
            .padding(.vertical, 2)
        }
    }

    /// 通知链全局预算(48 条)不够覆盖所有 pending 事项时提示,超出的事项本轮
    /// 没有排上通知,需要打开 app 才能看到提醒(极端场景:同时 48+ 个待办)。
    private var notificationOverflowSection: some View {
        Section {
            Label("有 \(NotificationBudgetState.shared.overflowCount) 个事项因通知数量已达系统上限,需要打开 app 才能看到提醒",
                  systemImage: "bell.badge.fill")
                .foregroundStyle(LodoColor.critical)
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
        // 胶囊和周条选中的那天是两个互斥的"看哪些"——点胶囊就把那天取消掉,
        // 否则点了半天列表纹丝不动(它还在显示选中的那一天)。
        .onChange(of: filter) { _, _ in
            if selectedDay != nil {
                withAnimation(.lodoAware(.lodoQuickFade)) { selectedDay = nil }
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
                withAnimation(.lodoAware(.snappy)) { filter = option }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .font(.body.weight(.semibold))
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(option.title) {
                withAnimation(.lodoAware(.snappy)) { filter = option }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.body.weight(.semibold))
        }
    }

    /// 混排行的分支渲染:待办事项走 TaskRowView,定时任务走 RoutineRowView
    /// (今天/未来/全部三个筛选态共用)。
    @ViewBuilder
    private func todoRow(_ row: TodoRow) -> some View {
        switch row.kind {
        case .task(let task):
            TaskRowView(task: task, now: now,
                        onEdit: { sheet = .edit(task, nil) },
                        onAskDuration: { title, planned in
                            askDurationQueue.append((title, planned))
                        })
        case .routine(let routine):
            RoutineRowView(routine: routine, now: now,
                          latestRunToday: latestRunToday(routine),
                          onEdit: { sheet = .editRoutine(routine) })
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

    /// 取这一周的系统日历事件。开关关着/没授权时 `CalendarBridge` 返回空数组,
    /// 这里不必自己判断。
    private func reloadWeekEvents() {
        #if DEBUG
        if demoCalendar { return }
        #endif
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        weekEvents = CalendarBridge.events(from: weekStart, to: end)
    }

    /// 顶部常驻的一周视图。事件在 `.task(id:)` 里按周加载(见 body 下面),
    /// 这里只把"某天有没有东西"的判断喂给它。
    private var weekStripSection: some View {
        Section {
            TaskWeekStrip(
                weekStart: $weekStart, selectedDay: $selectedDay,
                hasTask: { day in
                    pending.contains { Calendar.current.isDate(effectiveDay($0), inSameDayAs: day) }
                        || routines.contains { routine in
                            guard let routineDay = effectiveRoutineDay(routine) else { return false }
                            return Calendar.current.isDate(routineDay, inSameDayAs: day)
                        }
                },
                hasEvent: { day in weekEvents.contains { $0.occurs(on: day) } })
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12))
        .listRowBackground(Color.clear)
    }

    /// 周条选中某一天:那天的任务 + 定时任务 + 系统日历事件,按时间混排。
    /// 任务用的是和"全部"一样的 `effectiveDay`(逾期的冒泡到今天),事件按
    /// 区间相交判断(跨天的中间几天也算),全天事件排最前面。
    @ViewBuilder
    private func daySection(_ day: Date) -> some View {
        let calendar = Calendar.current
        let rows = allRowsGroupedByDay
            .first { calendar.isDate($0.date, inSameDayAs: day) }?.rows ?? []
        let events = weekEvents.filter { $0.occurs(on: day) }
            .sorted { $0.sortDate(on: day) < $1.sortDate(on: day) }
        Section {
            if rows.isEmpty && events.isEmpty {
                Text("这天没有安排").foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                CalendarEventRow(event: event)
                    // 别人家日历里的日程默认只读展示;左滑「转为任务」认领成
                    // lodo 任务(带纠缠式提醒),认领之后这条也进入双向同步,
                    // 见 CalendarSync.importEvent。只在写开关开着时给——
                    // 双向整套都由那个开关门控。
                    .swipeActions(edge: .trailing) {
                        if AppSettings.calendarWriteEnabled {
                            Button {
                                CalendarSync.importEvent(event, context: context)
                            } label: {
                                Label("转为任务", systemImage: "checklist")
                            }
                            .tint(.accentColor)
                        }
                    }
            }
            ForEach(rows) { row in
                todoRow(row)
            }
        } header: {
            Text(dayLabel(day))
        }
    }

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
            if pending.isEmpty && routines.isEmpty {
                ContentUnavailableView {
                    Label("暂无任务", systemImage: "checkmark.circle")
                } description: {
                    Text("跟 AI 说一句话就能新建,比如「明天下午3点开会」。")
                } actions: {
                    Button("开始添加") { sidebarChrome?.go(.agent) }
                        .glassProminentButton()
                }
            } else if todayRows.isEmpty {
                Text("今天暂无任务").foregroundStyle(.secondary)
            }
            ForEach(todayRows) { row in
                todoRow(row)
            }
        } header: {
            Text("今天任务")
        }
    }

    /// "未来"筛选态:明天及以后,平铺一个列表(每行自带日期,见 TaskItem.caption)。
    private var futureSection: some View {
        Section {
            if futureRows.isEmpty {
                Text("没有未来任务").foregroundStyle(.secondary)
            }
            ForEach(futureRows) { row in
                todoRow(row)
            }
        } header: {
            Text("未来任务")
        }
    }

    /// "全部"筛选态:全部待办(含到期未处理的)按天分 Section,上下滑动浏览。
    @ViewBuilder
    private var allSections: some View {
        if pending.isEmpty && routines.isEmpty {
            Section {
                Text("没有任务").foregroundStyle(.secondary)
            } header: {
                Text("全部任务")
            }
        } else {
            ForEach(allRowsGroupedByDay, id: \.date) { group in
                Section(dayLabel(group.date)) {
                    ForEach(group.rows) { row in
                        todoRow(row)
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(insight, systemImage: "sparkles")
                        .font(.body)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .nagSwipeActions(
            primaryLabel: "未完成", primarySystemImage: "arrow.uturn.backward", primaryTint: .orange,
            onPrimary: { restoreDoneTask(task) },
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
        task.ignoreStreak = 0
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

    // 新建/编辑落库等逻辑拆到同目录的 TodoListView+CRUD.swift。
    // (全局 agent 路由已随 AI 页独立出去,见 AgentHostView+Routing.swift。)
}
