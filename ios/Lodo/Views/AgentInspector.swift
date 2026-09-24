import SwiftUI
import SwiftData
import LodoCore
#if os(iOS)
import UIKit
#endif

// MARK: - 对外入口(经 Environment 下发)

/// AI 助手右侧栏的控制入口。对话里的卡片(规划/调整行程)靠它把右栏打开并定位到
/// 自己那份内容,不用一路串闭包——写法同 `SidebarChrome`。不在 AI 页时环境里是
/// nil,卡片据此回退到"切到旅行页"。
struct AgentInspectorController {
    /// 当前右栏会展示的内容;nil = 这个对话里还没有可展示的东西。
    let target: AgentInspectorTarget?
    let isPresented: Bool
    /// 打开右栏并定位到指定内容(卡片上的「查看」)。
    let show: (AgentInspectorTarget) -> Void
    /// 导航栏那颗按钮:开/关,宽屏上同时记住"固定"。
    let toggle: () -> Void
}

private struct AgentInspectorKey: EnvironmentKey {
    static let defaultValue: AgentInspectorController? = nil
}

extension EnvironmentValues {
    var agentInspector: AgentInspectorController? {
        get { self[AgentInspectorKey.self] }
        set { self[AgentInspectorKey.self] = newValue }
    }
}

/// 窄屏右栏是否拉出来了(含拖到一半)。外壳据此让开左抽屉的唤出手势——
/// 否则在右栏上往右拖收回时,会顺手把左边抽屉也拉出来。
struct AgentInspectorPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct AgentInspectorToolbarButton: ViewModifier {
    @Environment(\.agentInspector) private var inspector
    @Environment(\.sidebarChrome) private var chrome

    func body(content: Content) -> some View {
        content.toolbar {
            if let inspector, inspector.target != nil, !(chrome?.hidesChrome ?? false) {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: inspector.toggle) {
                        Image(systemName: "sidebar.trailing")
                    }
                    .accessibilityLabel(inspector.isPresented ? "隐藏详情" : "显示详情")
                }
            }
        }
    }
}

extension View {
    /// 导航栏右上那颗"显示详情"。只在当前对话有可展示内容时出现——
    /// 窄屏上左滑唤出不好发现,这颗按钮是明面上的入口。
    func agentInspectorToolbarButton() -> some View {
        modifier(AgentInspectorToolbarButton())
    }
}

// MARK: - 容器

/// 把 AI 对话页包成"左对话、右详情"。
///
/// - 宽屏(iPad 常规宽度 / macOS):系统 `.inspector`,理想宽度取可用宽的一半
///   (左右大致 5:5),用户可以拖分隔线;开着 = 固定,记在 `agentInspectorPinnedKey`,
///   固定时对话里一出现新的规划/调整,右栏就直接跟过去。
/// - 窄屏(iPhone、分屏):和左侧抽屉镜像的自绘容器——整页往左拖唤出,对话整块
///   左推压暗,只留一条边;点那条边或在上面往右拖收回。面板里装的仍是系统 List/Map,
///   不是新的自绘 UI。窄屏的 `.inspector` 会退化成 sheet,所以这里不用它。
///
/// 默认内容是对话里最新的那份(`AgentInspectorTarget.latest`),新的一到就跟过去;
/// 点卡片上的「查看」可以临时指到更早那张,下一份新内容到来时再回到跟随最新。
struct AgentInspectorHost<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.sectionIsActive) private var sectionIsActive
    @AppStorage(AppSettings.agentInspectorPinnedKey) private var pinned = false

    @State private var latest: AgentInspectorTarget?
    @State private var lastMessageUUID: UUID?
    /// 点「查看」指定的内容;nil = 跟随最新。
    @State private var explicit: AgentInspectorTarget?
    @State private var isPresented = false
    @State private var width: CGFloat = 0

    // 窄屏拖拽,判定方式照抄 AppShellView.sidebarDrag。
    @State private var dragOffset: CGFloat = 0
    @State private var dragSession: (start: CGPoint, claimed: Bool)?
    @GestureState private var isDragging = false
    @State private var exclusions: [CGRect] = []
    @State private var isClosing = false
    #if DEBUG
    @State private var demoPresented = false
    #endif

    private var target: AgentInspectorTarget? { explicit ?? latest }

    private var usesRegularLayout: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    private var animation: Animation {
        reduceMotion ? .linear(duration: 0.05) : .lodoSidebar
    }

    /// 窄屏面板宽度:左边留 44pt 露出对话(点它收回),大屏手机也不超过 480。
    private var panelWidth: CGFloat {
        max(1, min(width - 44, 480))
    }

    /// 0 = 收起,1 = 完全拉出;拖拽期间取中间值。
    private var progress: CGFloat {
        let base: CGFloat = isPresented ? 1 : 0
        return min(1, max(0, base - dragOffset / panelWidth))
    }

    var body: some View {
        Group {
            if usesRegularLayout {
                regularLayout
            } else {
                compactLayout
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background {
            AgentInspectorObserver { newLatest, last in
                latestChanged(newLatest, last: last)
            }
        }
        .onChange(of: usesRegularLayout) { _, regular in
            // 旋转/分屏切换布局:窄屏的临时面板不带进宽屏,宽屏按"固定"恢复。
            dragOffset = 0
            isPresented = regular && pinned && target != nil
        }
        .environment(\.agentInspector, AgentInspectorController(
            target: target, isPresented: isPresented, show: show, toggle: toggle))
        .preference(key: AgentInspectorPresentedKey.self,
                    value: sectionIsActive && !usesRegularLayout && (progress > 0 || isClosing))
    }

    // MARK: 宽屏

    private var regularLayout: some View {
        content
            .inspector(isPresented: $isPresented) {
                inspectorContent
                    .inspectorColumnWidth(min: 320, ideal: max(320, width * 0.5),
                                          max: max(320, width * 0.7))
            }
            .onChange(of: isPresented) { _, presented in
                // 三列(导航侧栏 + 对话 + 右栏)挤不下 5:5,打开右栏时收起导航侧栏;
                // 关掉右栏不自动再展开,用户要的话按 ☰。
                if presented, width < 900 { sidebarChrome?.collapse() }
            }
            .onAppear {
                if pinned, target != nil { isPresented = true }
            }
    }

    // MARK: 窄屏

    private var compactLayout: some View {
        ZStack(alignment: .trailing) {
            content
                // 拉开期间撤掉对话页导航栏上的按钮(☰、标题、右上角这颗),理由同
                // 左抽屉:工具栏不一定跟着内容平移,留着会浮在右栏上面还能点。
                .environment(\.sidebarChrome, chromeForContent)
                .simultaneousGesture(canOpenByDrag ? drag() : nil)
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
                .overlay {
                    if progress > 0 {
                        (colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
                            .opacity(progress)
                            .contentShape(Rectangle())
                            .onTapGesture { dismiss() }
                            .gesture(drag())
                            .accessibilityElement()
                            .accessibilityLabel("关闭详情")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { dismiss() }
                            .accessibilityHidden(!isPresented)
                    }
                }
                .offset(x: -progress * panelWidth)

            if target != nil {
                inspectorContent
                    .frame(width: panelWidth)
                    // 右栏和左抽屉是镜像关系,材质也跟着走 Liquid Glass。
                    .background { GlassSurface() }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.18 * progress), radius: 14, x: 3)
                    .offset(x: (1 - progress) * (panelWidth + 20))
                    .accessibilityHidden(!isPresented)
                    .accessibilityAddTraits(isPresented ? .isModal : [])
                    .accessibilityAction(.escape) { dismiss() }
            }
        }
        .onPreferenceChange(SidebarDragExclusionKey.self) { exclusions = $0 }
        .onChange(of: isDragging) { _, active in
            guard !active, dragOffset != 0 else { return }
            dragSession = nil
            withAnimation(animation) { dragOffset = 0 }
        }
        .animation(animation, value: isPresented)
    }

    private var canOpenByDrag: Bool {
        target != nil && !isPresented && sectionIsActive && !(sidebarChrome?.hidesChrome ?? false)
    }

    private var chromeForContent: SidebarChrome? {
        guard let chrome = sidebarChrome else { return nil }
        return SidebarChrome(open: chrome.open, go: chrome.go, collapse: chrome.collapse,
                             hidesChrome: chrome.hidesChrome || progress > 0 || isClosing)
    }

    private func drag() -> some Gesture {
        // 和横向胶囊行申报的矩形放在同一个具名空间里比对(外壳定义的那个)。
        DragGesture(minimumDistance: 12, coordinateSpace: .named(SidebarDragExclusion.spaceName))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                let claimed: Bool
                if let session = dragSession, session.start == value.startLocation {
                    claimed = session.claimed
                } else {
                    // 第一帧定归属:横向为主 + 方向对(收起时往左开、拉开时往右关)。
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    let rightDirection = isPresented
                        ? value.translation.width > 0 : value.translation.width < 0
                    let excluded = !isPresented && exclusions.contains {
                        $0.contains(value.startLocation)
                    }
                    claimed = horizontal && rightDirection && !excluded && target != nil
                    dragSession = (value.startLocation, claimed)
                    if claimed, !isPresented { endEditing() }
                }
                guard claimed else { return }
                dragOffset = isPresented
                    ? max(0, value.translation.width) : min(0, value.translation.width)
            }
            .onEnded { value in
                let claimed = dragSession?.claimed == true
                dragSession = nil
                guard claimed else { return }
                let opening = !isPresented
                let sign: CGFloat = opening ? -1 : 1
                let passed = value.translation.width * sign > panelWidth * 0.3
                    || value.predictedEndTranslation.width * sign > panelWidth * 0.5
                if passed ? opening : isPresented {
                    withAnimation(animation) {
                        dragOffset = 0
                        isPresented = true
                    }
                } else {
                    closeAnimated()
                }
            }
    }

    // MARK: 内容

    private var inspectorContent: some View {
        AgentInspectorContent(target: target, lastMessageUUID: lastMessageUUID,
                              onResolved: { resolved in
                                  if explicit != nil { explicit = resolved }
                              },
                              onClose: dismiss)
    }

    // MARK: 开合

    private func latestChanged(_ newLatest: AgentInspectorTarget?, last: UUID?) {
        let changed = newLatest != latest
        latest = newLatest
        lastMessageUUID = last
        guard changed else { return }
        // 出现了新的一份(或原来那份被写入/撤销了):回到跟随最新。
        explicit = nil
        if newLatest == nil {
            if usesRegularLayout { isPresented = false } else { dismissInstantly() }
        } else if usesRegularLayout, pinned {
            isPresented = true
        }
        #if DEBUG
        if newLatest != nil, !demoPresented,
           ProcessInfo.processInfo.arguments.contains("--demo-agent-inspector") {
            demoPresented = true
            isPresented = true
        }
        #endif
    }

    private func show(_ requested: AgentInspectorTarget) {
        explicit = requested == latest ? nil : requested
        endEditing()
        if usesRegularLayout {
            isPresented = true
            pinned = true
        } else {
            withAnimation(animation) { isPresented = true }
        }
    }

    private func toggle() {
        if isPresented {
            dismiss()
        } else if let target {
            show(target)
        }
    }

    private func dismiss() {
        if usesRegularLayout {
            isPresented = false
            pinned = false
        } else {
            closeAnimated()
        }
    }

    private func closeAnimated() {
        guard isPresented || dragOffset != 0 else { return }
        isClosing = true
        withAnimation(animation, completionCriteria: .removed) {
            dragOffset = 0
            isPresented = false
        } completion: {
            isClosing = false
        }
    }

    private func dismissInstantly() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = 0
            isClosing = false
            isPresented = false
        }
    }

    /// 拉出右栏时收起键盘,不然键盘会盖住面板下半截。
    private func endEditing() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        #endif
    }
}

/// 盯着对话的消息,把"最新那份可展示内容"报给容器。单独拆一个视图是为了
/// 用 @Query:规划写入/撤销改写的是消息上的快照,@Query 盯的正是消息,
/// 卡片上一点,这里就能重算。
///
/// 对话是单一持续时间线、永不结束,所以这里**倒序取最近 50 条**而不是全表——
/// 它只要算出"最新那份",再往前翻也不会改变结果,没必要把整条历史实例化出来
/// (AI 页现在还是冷启动的落地页,这段就在启动路径上)。
private struct AgentInspectorObserver: View {
    @Query private var messages: [AgentMessage]
    let onChange: (AgentInspectorTarget?, UUID?) -> Void

    private struct Snapshot: Equatable {
        let latest: AgentInspectorTarget?
        let last: UUID?
    }

    init(onChange: @escaping (AgentInspectorTarget?, UUID?) -> Void) {
        var descriptor = FetchDescriptor<AgentMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 50
        _messages = Query(descriptor)
        self.onChange = onChange
    }

    /// @Query 取的是倒序,算之前翻回正序(`latest(in:)` 约定入参按时间升序)。
    private var ordered: [AgentMessage] { messages.reversed() }

    private var snapshot: Snapshot {
        Snapshot(latest: AgentInspectorTarget.latest(in: ordered), last: ordered.last?.uuid)
    }

    var body: some View {
        Color.clear
            .onAppear { onChange(snapshot.latest, snapshot.last) }
            .onChange(of: snapshot) { _, new in onChange(new.latest, new.last) }
    }
}

// MARK: - 右栏内容

/// 右栏里那一页:自带 NavigationStack(旅行详情的工具栏和 sheet 要它),
/// 左上角一颗关闭。
struct AgentInspectorContent: View {
    let target: AgentInspectorTarget?
    /// 对话里最后一条消息;规划首次写入只允许最新那张(同卡片上的规则)。
    let lastMessageUUID: UUID?
    /// 预览里点了「写入行程」之后,右栏改指向那次真实的旅行。
    let onResolved: (AgentInspectorTarget) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch target {
                case .trip(let uuid):
                    InspectorTripView(tripUUID: uuid)
                case .tripPlan(let uuid):
                    InspectorPlanView(messageUUID: uuid, lastMessageUUID: lastMessageUUID,
                                      onResolved: onResolved)
                case nil:
                    ContentUnavailableView("暂无可展示的内容", systemImage: "sidebar.trailing",
                                           description: Text("在对话里规划或调整行程后,会显示在这里。"))
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭详情")
                }
            }
        }
    }
}

private struct InspectorTripView: View {
    @Query private var trips: [TravelTrip]

    init(tripUUID: UUID) {
        _trips = Query(filter: #Predicate<TravelTrip> { $0.uuid == tripUUID })
    }

    var body: some View {
        if let trip = trips.first {
            TravelDetailView(trip: trip)
        } else {
            ContentUnavailableView("这次旅行已经删除", systemImage: "suitcase",
                                   description: Text("可能在旅行页里删掉了,或者撤销了写入。"))
        }
    }
}

private struct InspectorPlanView: View {
    @Query private var messages: [AgentMessage]
    let lastMessageUUID: UUID?
    let onResolved: (AgentInspectorTarget) -> Void

    init(messageUUID: UUID, lastMessageUUID: UUID?,
         onResolved: @escaping (AgentInspectorTarget) -> Void) {
        _messages = Query(filter: #Predicate<AgentMessage> { $0.uuid == messageUUID })
        self.lastMessageUUID = lastMessageUUID
        self.onResolved = onResolved
    }

    var body: some View {
        if let message = messages.first {
            // 已经写入的规划直接看真实的那次旅行(之后的调整也改在它上面)。
            if case .trip(let trip)? = AgentInspectorTarget.from(message) {
                InspectorTripView(tripUUID: trip)
            } else {
                TripPlanPreviewView(message: message,
                                    isLatest: message.uuid == lastMessageUUID,
                                    onApplied: onResolved)
            }
        } else {
            ContentUnavailableView("这份规划已经不在了", systemImage: "map",
                                   description: Text("对应的对话消息被删除了。"))
        }
    }
}

/// 还没写入的规划:按天列出全部安排(卡片上默认只展开第一天),底部「写入行程」。
/// 只读——要改就接着在左边对话里说,AI 会重新给一份。
private struct TripPlanPreviewView: View {
    let message: AgentMessage
    let isLatest: Bool
    let onApplied: (AgentInspectorTarget) -> Void

    @Environment(\.modelContext) private var context

    private var plan: TripPlanProposal? {
        guard let data = message.tripPlanSnapshotData else { return nil }
        return try? JSONDecoder().decode(TripPlanProposal.self, from: data)
    }

    var body: some View {
        if let plan {
            list(plan)
        } else {
            Text(message.content)
        }
    }

    private func list(_ plan: TripPlanProposal) -> some View {
        let days = plan.days()
        let grouped = TravelPlan.group(plan.entries, into: days).filter { !$0.entries.isEmpty }
        let extras = TravelPlan.outOfRange(plan.entries, days: days)
            + TravelPlan.unscheduled(plan.entries)
        // 写过又撤销的可以随时重新写入(同卡片);从没写过的只认最新那张。
        let canApply = plan.appliedTripUUID != nil || isLatest

        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.tripTitle)
                        .font(.title2.bold())
                    Text("\(TripPlanFormat.dateRange(plan)) · \(days.count) 天 · \(plan.items.count) 项安排")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if !plan.summary.isEmpty {
                        Text(plan.summary)
                            .font(.body)
                            .padding(.top, 2)
                    }
                    Label("AI 规划 · 尚未写入行程", systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
            ForEach(grouped) { day in
                Section {
                    ForEach(day.entries) { TripPlanEntryRow(entry: $0) }
                } header: {
                    TripPlanFormat.dayTitle(day.date, in: plan)
                }
            }
            if !extras.isEmpty {
                Section("其他安排") {
                    ForEach(extras) { TripPlanEntryRow(entry: $0) }
                }
            }
        }
        .navigationTitle("行程预览")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            if canApply {
                Button {
                    let applied = TripPlanApplier.apply(plan, to: message, context: context)
                    if let trip = applied.appliedTripUUID { onApplied(.trip(trip)) }
                } label: {
                    Label(plan.appliedTripUUID != nil ? "重新写入" : "写入行程",
                          systemImage: "suitcase.rolling")
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}
