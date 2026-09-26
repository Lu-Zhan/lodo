import SwiftUI
import SwiftData
import LodoCore
#if os(iOS)
import EventKit
#endif

/// 「日历」页:只显示**系统日历**里的日程(lodo 自己那本镜像任务的日历不显示——
/// 任务在任务页看;旅行行程也暂时不进来)。右上角切换 所有/当日/三日/本周/
/// 本月/全年 六种视图,参考系统日历 app;底部照常是「问问 AI」。
///
/// 授权之后可以直接改用户已有的日程:点开一条事件走系统的 `EKEventViewController`
/// (见 `CalendarEventSheet`),编辑/删除都由用户在系统界面里自己确认。
///
/// 区间、翻页、月格、时间轴分列这些判断全在 `LodoCore/CalendarViewPlan.swift`
/// (`CalendarViewPlanTests`),这里只管取数和摆放。
struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.sectionIsActive) private var sectionIsActive

    @AppStorage(AppSettings.calendarEnabledKey) private var calendarEnabled = false
    @AppStorage(AppSettings.calendarWriteEnabledKey) private var calendarWriteEnabled = false
    /// 上次看的是哪种视图,下次进来接着用(纯展示偏好,只存本机)。
    @AppStorage(AppSettings.calendarViewModeKey) private var modeRaw = CalendarViewMode.week.rawValue

    @State private var anchor = Calendar.current.startOfDay(for: Date())
    /// 月视图里选中的那天(下方列表显示它)。
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var events: [CalendarEvent] = []
    @State private var authorized = CalendarBridge.isAuthorized
    @State private var denied = CalendarBridge.isDenied
    #if os(iOS)
    @State private var openedEvent: OpenedEvent?
    #endif
    #if DEBUG
    /// --demo-calendar 塞了样板事件:之后的真实查询要让开(同 HealthView 的 demoOverride)。
    @State private var demoCalendar = false
    #endif

    private let calendar = Calendar.current

    private var mode: CalendarViewMode {
        CalendarViewMode(rawValue: modeRaw) ?? .week
    }

    private var isConnected: Bool {
        #if DEBUG
        if demoCalendar { return true }
        #endif
        return calendarEnabled && authorized
    }

    /// 写开关开着时才给「转为任务」(双向整套都由那个开关门控)。
    private var convertToTask: ((CalendarEvent) -> Void)? {
        guard calendarWriteEnabled else { return nil }
        return { event in CalendarSync.importEvent(event, context: context) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isConnected {
                    VStack(spacing: 0) {
                        if mode != .agenda { periodHeader }
                        content
                    }
                } else {
                    connectPrompt
                }
            }
            .navigationTitle("日历")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false), isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button("今天") { goToToday() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        modeMenu
                    }
                }
            }
            .askBar(focus: .calendar)
            .task(id: ReloadKey(mode: mode, anchor: anchor, connected: isConnected)) { reload() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshAuthorization()
                reload()
            }
            #if os(iOS)
            // 用户在系统日历 app 里改了、或者在我们弹出的编辑界面里保存了,都会发这条。
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                reload()
            }
            .sheet(item: $openedEvent) { opened in
                CalendarEventSheet(event: opened.event) {
                    openedEvent = nil
                    reload()
                }
                .ignoresSafeArea()
            }
            #endif
            .onAppear {
                refreshAuthorization()
                #if DEBUG
                applyDemoArguments()
                #endif
            }
        }
    }

    // MARK: - 顶部

    /// 右上角的视图切换。用 Picker 放在 Menu 里,选中项自带对号。
    private var modeMenu: some View {
        Menu {
            Picker("视图", selection: Binding(
                get: { mode },
                set: { newMode in switchMode(to: newMode) })) {
                ForEach(CalendarViewMode.allCases, id: \.self) { option in
                    Label(LocalizedStringKey(option.title), systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            Label(LocalizedStringKey(mode.title), systemImage: mode.systemImage)
        }
        .accessibilityLabel("切换视图")
    }

    /// 翻页条:‹ 这一页是哪段时间 ›。中间那行字点一下回到今天。
    private var periodHeader: some View {
        HStack {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .hitTarget(visualSize: 28)
            }
            .pressable()
            .accessibilityLabel("上一页")
            Spacer()
            Button {
                goToToday()
            } label: {
                Text(periodLabel)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .pressable()
            Spacer()
            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .hitTarget(visualSize: 28)
            }
            .pressable()
            .accessibilityLabel("下一页")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var periodLabel: String {
        switch mode {
        case .agenda:
            return ""
        case .day:
            return anchor.formatted(.dateTime.year().month().day().weekday())
        case .threeDay, .week:
            let days = CalendarViewPlan.timelineDays(anchor: anchor, mode: mode, calendar: calendar)
            guard let first = days.first, let last = days.last else { return "" }
            return (first..<last).formatted(.interval.month().day())
        case .month:
            return anchor.formatted(.dateTime.year().month(.wide))
        case .year:
            return anchor.formatted(.dateTime.year())
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .agenda:
            agendaList
        case .day, .threeDay, .week:
            CalendarTimelineView(
                days: CalendarViewPlan.timelineDays(anchor: anchor, mode: mode, calendar: calendar),
                events: events,
                weekStripAnchor: mode == .day ? anchor : nil,
                onSelectDay: { day in withAnimation(.lodoAware(.lodoQuickFade)) { anchor = day } },
                onOpen: open, convertToTask: convertToTask)
            .pagingSwipe(isActive: sectionIsActive) { shift(by: $0) }
        case .month:
            CalendarMonthView(
                month: anchor, events: events, selectedDay: $selectedDay,
                onOpenDay: { day in
                    anchor = day
                    modeRaw = CalendarViewMode.day.rawValue
                },
                onOpen: open, convertToTask: convertToTask)
            .pagingSwipe(isActive: sectionIsActive) { shift(by: $0) }
        case .year:
            CalendarYearView(year: anchor, events: events) { month in
                withAnimation(.lodoAware(.lodoQuickFade)) {
                    modeRaw = CalendarViewMode.month.rawValue
                    anchor = month
                    selectedDay = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
                        ? calendar.startOfDay(for: Date()) : month
                }
            }
            .pagingSwipe(isActive: sectionIsActive) { shift(by: $0) }
        }
    }

    /// 所有:按天分组的列表,打开时定位到今天(或今天之后最近有日程的那天)。
    private var agendaList: some View {
        let range = CalendarViewPlan.queryRange(anchor: anchor, mode: .agenda, calendar: calendar)
        let groups = CalendarViewPlan.agendaGroups(events, in: range, calendar: calendar)
        let today = calendar.startOfDay(for: Date())
        let target = groups.first { $0.day >= today }?.day
        return ScrollViewReader { proxy in
            List {
                if groups.isEmpty {
                    Text("近期没有日程").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.day) { group in
                    Section {
                        ForEach(group.events, id: \.occurrenceKey) { event in
                            CalendarEventRow(event: event, day: group.day, onOpen: open,
                                             convertToTask: convertToTask)
                        }
                    } header: {
                        dayHeader(group.day)
                    }
                    .id(group.day)
                }
            }
            .listStyle(.plain)
            .onAppear {
                guard let target else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
            }
            .onChange(of: target) { _, new in
                guard let new else { return }
                proxy.scrollTo(new, anchor: .top)
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 6) {
            if calendar.isDateInToday(day) {
                Text("今天")
            } else if calendar.isDateInTomorrow(day) {
                Text("明天")
            }
            Text(day, format: .dateTime.month().day().weekday())
        }
    }

    // MARK: - 未连接

    private var connectPrompt: some View {
        ContentUnavailableView {
            Label("连接系统日历", systemImage: "calendar")
        } description: {
            #if os(iOS)
            if denied {
                Text("日历访问权限已关闭。到系统「设置 → 隐私与安全性 → 日历」里允许 lodo 访问后,这里会显示你的日程。")
            } else {
                Text("授权后这里会显示你日历里的日程,点开任意一条可以直接修改。lodo 不会替你改任何内容,改动都要你在编辑界面里确认。")
            }
            #else
            Text("macOS 版暂不支持连接系统日历。")
            #endif
        } actions: {
            #if os(iOS)
            if denied {
                Button("前往系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .glassProminentButton()
            } else {
                Button("连接日历") { connect() }
                    .glassProminentButton()
            }
            #endif
        }
    }

    // MARK: - 动作

    private func connect() {
        calendarEnabled = true
        Task { @MainActor in
            await CalendarBridge.requestAccess()
            refreshAuthorization()
            reload()
        }
    }

    private func refreshAuthorization() {
        authorized = CalendarBridge.isAuthorized
        denied = CalendarBridge.isDenied
    }

    private func reload() {
        #if DEBUG
        if demoCalendar { return }
        #endif
        guard isConnected else { return }
        let range = CalendarViewPlan.queryRange(anchor: anchor, mode: mode, calendar: calendar)
        events = CalendarBridge.events(from: range.lowerBound, to: range.upperBound)
    }

    private func open(_ event: CalendarEvent) {
        #if os(iOS)
        #if DEBUG
        if demoCalendar { return }
        #endif
        guard let ekEvent = CalendarBridge.ekEvent(for: event) else {
            // 事件在这期间被删了(或者换了 id):重取一遍,那一条自然就消失了。
            reload()
            return
        }
        openedEvent = OpenedEvent(event: ekEvent)
        #endif
    }

    private func shift(by pages: Int) {
        withAnimation(.lodoAware(.lodoQuickFade)) {
            anchor = CalendarViewPlan.shift(anchor, mode: mode, by: pages, calendar: calendar)
            if mode == .month {
                selectedDay = calendar.isDate(anchor, equalTo: Date(), toGranularity: .month)
                    ? calendar.startOfDay(for: Date()) : anchor
            }
        }
    }

    private func goToToday() {
        withAnimation(.lodoAware(.lodoQuickFade)) {
            anchor = CalendarViewPlan.anchor(for: Date(), mode: mode, calendar: calendar)
            selectedDay = calendar.startOfDay(for: Date())
        }
    }

    /// 换视图时尽量停在"同一段时间":从本月切到当日,落在月视图里选中的那天;
    /// 其余情况落在当前锚点附近(今天在这一页里就落在今天)。
    private func switchMode(to newMode: CalendarViewMode) {
        let reference: Date
        if mode == .month {
            reference = selectedDay
        } else {
            let range = CalendarViewPlan.queryRange(anchor: anchor, mode: mode, calendar: calendar)
            reference = range.contains(Date()) ? Date() : anchor
        }
        withAnimation(.lodoAware(.lodoQuickFade)) {
            modeRaw = newMode.rawValue
            anchor = CalendarViewPlan.anchor(for: reference, mode: newMode, calendar: calendar)
            selectedDay = calendar.startOfDay(for: reference)
        }
    }

    // MARK: - 截图

    #if DEBUG
    /// 模拟器点不了系统日历的授权弹窗,直接塞一周样板事件(只落 @State,
    /// 不写 UserDefaults、不碰真实日历)。`--demo-calendar-<mode>` 选视图。
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-calendar") else { return }
        demoCalendar = true
        let today = calendar.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Double) -> Date {
            today.addingTimeInterval(Double(dayOffset) * 86400 + hour * 3600)
        }
        let work = CalendarEventColor(red: 0.20, green: 0.47, blue: 0.96)
        let home = CalendarEventColor(red: 0.30, green: 0.69, blue: 0.31)
        let family = CalendarEventColor(red: 0.85, green: 0.35, blue: 0.62)
        events = [
            CalendarEvent(id: "d1", title: "产品评审", start: at(0, 10), end: at(0, 11.5),
                          isAllDay: false, calendarTitle: "工作", calendarColor: work, location: "3 楼会议室"),
            CalendarEvent(id: "d2", title: "和设计对稿", start: at(0, 10.5), end: at(0, 11),
                          isAllDay: false, calendarTitle: "工作", calendarColor: work),
            CalendarEvent(id: "d3", title: "体检", start: today, end: at(1, 0),
                          isAllDay: true, calendarTitle: "个人", calendarColor: home),
            CalendarEvent(id: "d4", title: "牙医", start: at(1, 15), end: at(1, 16),
                          isAllDay: false, calendarTitle: "个人", calendarColor: home, location: "仁爱口腔"),
            CalendarEvent(id: "d5", title: "周会", start: at(-1, 9), end: at(-1, 10),
                          isAllDay: false, calendarTitle: "工作", calendarColor: work),
            CalendarEvent(id: "d6", title: "妈妈生日", start: at(3, 0), end: at(4, 0),
                          isAllDay: true, calendarTitle: "家庭", calendarColor: family),
            CalendarEvent(id: "d7", title: "羽毛球", start: at(2, 19), end: at(2, 21),
                          isAllDay: false, calendarTitle: "个人", calendarColor: home),
            CalendarEvent(id: "d8", title: "季度规划", start: at(8, 14), end: at(8, 17),
                          isAllDay: false, calendarTitle: "工作", calendarColor: work),
        ]
        let modes: [(String, CalendarViewMode)] = [
            ("--demo-calendar-agenda", .agenda), ("--demo-calendar-day", .day),
            ("--demo-calendar-three", .threeDay), ("--demo-calendar-week", .week),
            ("--demo-calendar-month", .month), ("--demo-calendar-year", .year),
        ]
        if let picked = modes.first(where: { args.contains($0.0) })?.1 {
            modeRaw = picked.rawValue
        }
        anchor = CalendarViewPlan.anchor(for: Date(), mode: mode, calendar: calendar)
    }
    #endif
}

private struct ReloadKey: Equatable {
    let mode: CalendarViewMode
    let anchor: Date
    let connected: Bool
}

#if os(iOS)
private struct OpenedEvent: Identifiable {
    let id = UUID()
    let event: EKEvent
}
#endif

extension CalendarViewMode {
    var systemImage: String {
        switch self {
        case .agenda: return "list.bullet"
        case .day: return "calendar.day.timeline.left"
        case .threeDay: return "rectangle.split.3x1"
        case .week: return "calendar.day.timeline.leading"
        case .month: return "calendar"
        case .year: return "square.grid.3x3"
        }
    }
}

extension View {
    /// 左右滑翻页(左滑下一页)。整块内容区向抽屉申报排除——理由同
    /// `HorizontalChipRow`:往右滑看上一页会顺手把抽屉拖出来。抽屉在这一页
    /// 靠左上角的 ☰ 打开。
    func pagingSwipe(isActive: Bool, onPage: @escaping (Int) -> Void) -> some View {
        self
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarDragExclusionKey.self,
                        value: isActive
                            ? [proxy.frame(in: .named(SidebarDragExclusion.spaceName))]
                            : [])
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width
                        guard abs(dx) > abs(value.translation.height) * 1.5, abs(dx) > 60 else { return }
                        onPage(dx < 0 ? 1 : -1)
                    }
            )
    }
}
