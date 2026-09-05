import SwiftUI
import SwiftData
import LodoCore
#if os(iOS)
import UIKit
#endif

/// app 的四个平级页面。左滑抽屉(`AppSidebarView`)是它们之间唯一的切换入口——
/// 没有底部标签栏,也没有"AI 是从某个页面弹出来的模态"这回事。
enum AppSection: Hashable, CaseIterable {
    case overview, todo, memory, agent
}

// MARK: - 导航栏 ☰ 按钮(经 Environment 下发,四个页面共用)

/// 抽屉开关 + 当前是否该藏起导航栏上的自绘按钮。四个页面各自持有自己的
/// NavigationStack/toolbar,靠 Environment 拿到这两样东西,不用逐个加 init 参数。
struct SidebarChrome {
    let open: () -> Void
    /// 直接切到某个页面。页面内部偶尔需要把用户送到另一个页面(比如待办空态里
    /// 那颗"开始添加"要去 AI 页),不必为此再串一路闭包。
    let go: (AppSection) -> Void
    let hidesChrome: Bool
}

private struct SidebarChromeKey: EnvironmentKey {
    static let defaultValue: SidebarChrome? = nil
}

extension EnvironmentValues {
    var sidebarChrome: SidebarChrome? {
        get { self[SidebarChromeKey.self] }
        set { self[SidebarChromeKey.self] = newValue }
    }
}

private struct SidebarToolbarButton: ViewModifier {
    @Environment(\.sidebarChrome) private var chrome

    func body(content: Content) -> some View {
        content.toolbar {
            if let chrome, !chrome.hidesChrome {
                ToolbarItem(placement: .navigation) {
                    Button(action: chrome.open) {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("导航")
                }
            }
        }
    }
}

extension View {
    /// 在导航栏 leading 放一颗 ☰。抽屉推开时**整体移除**这个按钮而不是给它加
    /// .opacity(0)——工具栏挂在 NavigationStack 上、不跟着内容平移,留着的话
    /// 汉堡会浮在侧栏上面;而 iOS 26 工具栏按钮的 Liquid Glass 底是系统画的、
    /// 不跟 label 的透明度走,只调透明度会在顶上留下一个空玻璃圆圈。
    func sidebarToolbarButton() -> some View {
        modifier(SidebarToolbarButton())
    }
}

// MARK: - 抽屉容器

/// 导航外壳:左边是侧栏,右边是当前页面。窄屏(iPhone)侧栏是抽屉,展开时把
/// 内容整块推到右边并压暗;宽屏(iPad 常规宽度 / macOS)侧栏常驻并排,不推移。
/// 所有跨页导航状态(当前页面、深链交接、记忆页的 push 栈)都归这里持有。
struct AppShellView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var section: AppSection
    /// 已经打开过的页面。四个页面用 ZStack 叠着、只显示当前那个(切回来时筛选
    /// 胶囊/滚动位置还在,和原来 TabView 的行为一致),但**没打开过的不构建**
    /// ——总览页一挂载就会发起 AI 请求,不能因为它排在第一个就在启动时先跑一遍。
    @State private var visited: Set<AppSection>
    @State private var currentThreadUUID: UUID?
    @State private var showSettings = false

    /// 非 nil 时切到 AI 页并把文本预填进输入框(深链/Siri 交接/小组件"+")。
    @State private var agentRequest: String?
    /// 非 nil 时切到总览页并对该事项发起改期(通知"改期"按钮交接)。
    @State private var rescheduleRequestUUID: String?
    /// 非 nil 时切到待办页并弹出预填的新建表单(记忆条目"转为待办")。
    @State private var convertToTodoRequest: ConvertToTodoRequest?
    /// 非 nil 时切到记忆页并按这个标签筛选(侧栏标签行)。
    @State private var memoryTagFilter: String?
    /// 记忆页的 push 栈。提到这里持有有两个用处:深链回记忆页时能弹回根,
    /// 以及下面 swipeGestureEnabled 要知道现在是不是在二级页。
    @State private var memoryPath: [MemoryItem] = []

    /// 窄屏时表示抽屉是否展开,宽屏时表示常驻侧栏是否可见;两种布局共用同一个开关。
    @State private var showSidebar = false
    /// 宽屏默认展开常驻侧栏,窄屏默认收起。sizeClass 在 init 阶段读不到,
    /// 只能挂在第一次 onAppear 上做一次。
    @State private var didSetInitialSidebar = false
    /// 抽屉横向拖拽的实时位移。
    @State private var sidebarDragOffset: CGFloat = 0
    /// 本次拖拽的起点 + 归属判定;起点变了就说明换了一次新拖拽,重新判定。
    /// 不只靠 onEnded 复位:手势被系统中断时 onEnded 不一定会来,只靠它复位会让
    /// 下一次右滑整个失灵。
    @State private var dragSession: (start: CGPoint, intent: DragIntent)?
    /// 设备物理安全区顶部高度(灵动岛/状态栏),不含 NavigationStack 内部给导航栏
    /// 额外预留的那截——挂在最外层的 background 上量,量到的是原始安全区,
    /// 不会被页面内部的导航栏放大。窄屏抽屉拉到物理顶部时(sidebarPanel 忽略了
    /// 容器安全区)要拿这个值重新给侧栏 header 加回顶部间距,不然文字会被灵动岛
    /// 挡住;在 sidebarPanel 内部另开一个 GeometryReader 读不到这个值——那个
    /// 位置已经在忽略安全区的子树里,读到的是 0。
    @State private var deviceTopInset: CGFloat = 0
    /// 同上,底部那截(home indicator)。整个抽屉容器忽略安全区之后,侧栏底部
    /// 那排浮层按钮和页面内容都会一路贴到屏幕物理底边、被 home indicator 压住,
    /// 得手动加回来(侧栏用 padding,页面用 safeAreaInset)。
    @State private var deviceBottomInset: CGFloat = 0
    /// 键盘是否弹起。补回底部安全区那截是为了躲 home indicator,但键盘弹起时
    /// 系统的键盘安全区已经把内容顶上去了,这时再叠一截会让输入栏浮在键盘上方
    /// 34pt 处、中间空出一条。键盘期间归零即可。
    @State private var keyboardVisible = false

    /// 关闭手势(遮罩上左滑)是和内容并行挂着的,哪一方接管这次拖拽在**第一帧**
    /// 就定死、之后不再改判:否则先纵向滚一段、中途拐个横向,侧栏会毫无预兆地
    /// 跳出来。
    private enum DragIntent { case sidebar, ignored }

    init() {
        let initial: AppSection = Self.shouldOpenAgentOnLaunch() ? .agent : .overview
        _section = State(initialValue: initial)
        _visited = State(initialValue: [initial])
    }

    /// 冷启动直接落在 AI 页:首次引导还没做完时不算(会和引导全屏页叠在一起),
    /// 截图/UI 测试用的 --demo-* 场景也跳过,避免抢在目标页面之前打断自动化流程。
    /// UserDefaults/ProcessInfo 都是同步读取,init 里读没有副作用。
    private static func shouldOpenAgentOnLaunch() -> Bool {
        guard AppSettings.hasSeenOnboarding else { return false }
        guard AppSettings.openAgentOnLaunch else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--demo-") }) { return false }
        #endif
        return true
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        // 挂在最外层:量到的是原始安全区,不会被页面内部的导航栏放大。
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        deviceTopInset = proxy.safeAreaInsets.top
                        deviceBottomInset = proxy.safeAreaInsets.bottom
                    }
                    .onChange(of: proxy.safeAreaInsets.top) { _, newValue in
                        deviceTopInset = newValue
                    }
                    .onChange(of: proxy.safeAreaInsets.bottom) { _, newValue in
                        deviceBottomInset = newValue
                    }
            }
        )
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        #endif
        .environment(\.sidebarChrome,
                     SidebarChrome(open: toggleSidebar, go: go,
                                   hidesChrome: hidesToolbarChrome))
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: section) { _, new in visited.insert(new) }
        .onAppear {
            if !didSetInitialSidebar {
                didSetInitialSidebar = true
                showSidebar = horizontalSizeClass == .regular
            }
            #if DEBUG
            applyDemoArguments()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                #if os(iOS)
                consumeAgentHandoff()
                #endif
                consumeRescheduleHandoff()
            }
        }
        #if os(iOS)
        // Siri Intent 交接的快路径(app 已在运行时即时弹出)
        .onReceive(NotificationCenter.default.publisher(
            for: LodoIntentSupport.agentHandoff)) { note in
            UserDefaults.standard.removeObject(forKey: LodoIntentSupport.pendingAgentTextKey)
            openAgent(prefill: note.userInfo?["text"] as? String ?? "")
        }
        #endif
        // 通知"改期"按钮交接的快路径(app 已在前台时即时响应)
        .onReceive(NotificationCenter.default.publisher(
            for: NotificationManager.rescheduleHandoff)) { note in
            UserDefaults.standard.removeObject(forKey: NotificationManager.pendingRescheduleUUIDKey)
            go(.overview)
            rescheduleRequestUUID = note.userInfo?["uuid"] as? String
        }
        // 深链:lodo://add(小组件"+")/lodo://agent?text=…(Siri Intent 回退)
        // 切到 AI 页;lodo://memory(分享收藏后跳回)切到记忆页。
        .onOpenURL { url in
            guard url.scheme == "lodo" else { return }
            switch url.host {
            case "add":
                openAgent(prefill: "")
            case "agent":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "text" }?.value
                openAgent(prefill: text ?? "")
            case "memory":
                memoryPath = []
                go(.memory)
            default:
                break
            }
        }
    }

    // MARK: - 页面

    /// 四个页面叠在一起,只显示当前那个;没打开过的不构建(见 visited 的注释)。
    private var sectionStack: some View {
        ZStack {
            ForEach(AppSection.allCases, id: \.self) { candidate in
                if visited.contains(candidate) {
                    content(for: candidate)
                        .opacity(candidate == section ? 1 : 0)
                        .allowsHitTesting(candidate == section)
                        .accessibilityHidden(candidate != section)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for candidate: AppSection) -> some View {
        switch candidate {
        case .overview:
            OverviewView(rescheduleRequestUUID: $rescheduleRequestUUID)
        case .todo:
            TodoListView(convertToTodoRequest: $convertToTodoRequest)
        case .memory:
            MemoryListView(onConvertToTodo: convertToTodo,
                           path: $memoryPath, tagFilter: $memoryTagFilter)
        case .agent:
            AgentHostView(currentThreadUUID: $currentThreadUUID, agentRequest: $agentRequest)
        }
    }

    private var sidebarPanel: some View {
        AppSidebarView(
            section: $section,
            currentThreadUUID: $currentThreadUUID,
            onSelectTag: { tag in
                memoryTagFilter = tag
                memoryPath = []
                go(.memory)
            },
            onOpenSettings: { showSettings = true },
            onSelect: { if horizontalSizeClass != .regular { closeSidebar() } }
        )
        .padding(.top, horizontalSizeClass == .regular ? 0 : deviceTopInset)
        .padding(.bottom, horizontalSizeClass == .regular ? 0 : deviceBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignMetrics.panelBackground(colorScheme))
    }

    // MARK: - 抽屉机制

    private func go(_ target: AppSection) {
        section = target
        visited.insert(target)
    }

    private func openAgent(prefill: String) {
        go(.agent)
        agentRequest = prefill
    }

    private func toggleSidebar() {
        withAnimation(.lodoAware(.lodoSidebar)) { showSidebar.toggle() }
    }

    private func closeSidebar() {
        withAnimation(.lodoAware(.lodoSidebar)) { showSidebar = false }
    }

    /// 抽屉推开(或拖到一半)时撤掉页面导航栏上的 ☰。判据是 sidebarProgress 而不是
    /// showSidebar:拖到一半时 ☰ 同样会浮在已经露出来的那截侧栏上面,所以拖拽
    /// 一起手就得撤掉,不能等松手落定。宽屏常驻列不推移内容,☰ 照常显示。
    private var hidesToolbarChrome: Bool {
        horizontalSizeClass != .regular && sidebarProgress > 0
    }

    /// 侧栏推开时盖在页面上的那层遮罩:日间压一层半透明**白**——内容被洗淡、
    /// 卡片比侧栏更白,"这块暂时不能操作"的意思出来了,又不会像灰黑遮罩那样把
    /// 整张卡压成一块灰框;夜间白色反而刺眼,仍用半透明黑压暗。这层遮罩同时是
    /// "点一下关闭"和展开后"左滑收回"的手势承载层,不能省掉。
    private var sidebarScrim: some View {
        (colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
    }

    /// 0 = 完全收起,1 = 完全展开;拖拽期间取中间值,松手后回到 0/1。
    /// 抽屉的所有视觉量(推移/圆角/变暗)都从这一个进度插值出来,
    /// 开合两个方向才能同样跟手。
    private var sidebarProgress: CGFloat {
        let base: CGFloat = showSidebar ? 1 : 0
        return min(1, max(0, base + sidebarDragOffset / DesignMetrics.sidebarWidth))
    }

    /// 松手后按"已拖过 30% 宽 或 甩动预测能到 50% 宽"判定落到哪一端,开合对称。
    private func settleSidebar(_ value: DragGesture.Value, opening: Bool) {
        let width = DesignMetrics.sidebarWidth
        let sign: CGFloat = opening ? 1 : -1
        let passed = value.translation.width * sign > width * 0.3
            || value.predictedEndTranslation.width * sign > width * 0.5
        withAnimation(.lodoAware(.lodoSidebar)) {
            sidebarDragOffset = 0
            if passed { showSidebar = opening }
        }
    }

    /// 唤出 / 收回的手势本体:收起时挂在屏幕左边缘那条窄带上,展开后挂在遮罩上。
    private func sidebarDrag() -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let intent: DragIntent
                if let session = dragSession, session.start == value.startLocation {
                    intent = session.intent
                } else {
                    // 一次拖拽的第一帧:横向为主 + 方向对(收起时向右开、展开时
                    // 向左关)才接管;纵向滚动和反方向的横滑一律让给底下的视图。
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    let rightDirection = showSidebar
                        ? value.translation.width < 0 : value.translation.width > 0
                    intent = (horizontal && rightDirection) ? .sidebar : .ignored
                    dragSession = (value.startLocation, intent)
                }
                guard intent == .sidebar else { return }
                sidebarDragOffset = showSidebar
                    ? min(0, value.translation.width) : max(0, value.translation.width)
            }
            .onEnded { value in
                let wasSidebar = dragSession?.intent == .sidebar
                dragSession = nil
                if wasSidebar { settleSidebar(value, opening: !showSidebar) }
            }
    }

    /// 记忆页是四个页面里唯一能 push 二级页的(条目详情)。二级页里屏幕左边缘
    /// 归系统的返回手势,唤出手势必须整个让开,否则两者互抢、返回手势失灵。
    /// 手势从"只认左边缘窄带"改成整页之后这条更要紧了——不让开的话在详情页里
    /// 往右拖会开抽屉,而不是用户预期的返回。
    private var swipeGestureEnabled: Bool {
        section != .memory || memoryPath.isEmpty
    }

    /// 窄屏(iPhone、紧凑宽度 iPad):侧栏从左滑入,页面整体推移变暗。
    /// **整页任意位置**往右拖都能唤出(不再限于左边缘那条窄带);为此全 app 的
    /// 行操作都收在了向左滑那一侧,没有任何 leading action 跟它抢方向。
    /// 收回则是展开后在遮罩上任意位置左滑,或者点一下遮罩。
    private var compactLayout: some View {
        ZStack(alignment: .leading) {
            // 侧栏排在前面 = 画在底下:页面盖在它上面,页面的投影才能落到侧栏上。
            // 面板自己因此不带投影。面板常驻渲染,靠 offset 推到屏幕外表示收起
            // ——这样拖拽中间态才有东西可跟手(条件渲染 + transition 做不到跟手,
            // 只能播一段固定动画)。
            sidebarPanel
                // 拉到屏幕物理顶部,不吃页面 NavigationStack 给导航栏预留的那截
                // 安全区(展开时导航栏内容已经撤空,留着那截空白没意义)。
                .ignoresSafeArea(.container, edges: .top)
                .frame(width: DesignMetrics.sidebarWidth)
                .offset(x: -(1 - sidebarProgress) * DesignMetrics.sidebarWidth)
                .gesture(
                    DragGesture()
                        .onChanged { sidebarDragOffset = min(0, $0.translation.width) }
                        .onEnded { settleSidebar($0, opening: false) }
                )

            // 顺序要紧:先叠手势层和遮罩、再 clipShape 圆角,最后才推移。
            // clipShape 必须排在 offset 前面——offset 是布局中立的渲染位移,排在
            // 它后面的 clipShape 仍按"没被推移的原始 frame"裁切,圆角会落在被侧栏
            // 盖住的屏幕左边缘外,推出来的那张卡看上去就是一条笔直的硬边。遮罩也
            // 放进裁切范围内,不然方角的遮罩会盖住卡片的圆角。
            sectionStack
                // 页面底色 + 铺到物理屏幕边缘:各页面 List 的系统 grouped 背景只
                // 画在安全区之内,状态栏和 home indicator 那两截会露出窗口底色,
                // 推开时那张卡上下各短一截、44pt 圆角悬在屏幕中间。自己铺一层
                // 和侧栏同源的底色(DesignMetrics.panelBackground)并忽略安全区,
                // 卡才是完整的一块"设备屏幕"。
                //
                // 但外层那句 ignoresSafeArea 是连页面内容一起吃掉的:底色铺满了,
                // 页面内容也跟着压到 home indicator 上(AI 页输入栏最明显——原本
                // 18pt 底距叠在安全区之上,变成直接贴着屏幕底边,它自己 26pt 的
                // 玻璃圆角就和卡片 44pt 的圆角套成了两层角)。所以这里把底部那截
                // 安全区原样还给内容:背景层在 frame 上、仍然铺满,内容层收进来。
                // 顶部不用还——导航栏的让位是 UIKit 那侧按窗口安全区算的,不走
                // SwiftUI 这套 inset,实测没被吃掉。
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: keyboardVisible ? 0 : deviceBottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignMetrics.panelBackground(colorScheme))
                // 收起时手势挂在页面内容上,和列表的纵向滚动并行(sidebarDrag 第一帧
                // 就按"横向为主 + 方向对"定死归属,纵向滚动照常让给底下的视图)。
                .simultaneousGesture(showSidebar || !swipeGestureEnabled ? nil : sidebarDrag())
                // allowsHitTesting 只罩页面内容本身,不能挂到遮罩外面去——遮罩要
                // 继续吃"点一下关闭"和"左滑收回"这两个手势。
                .allowsHitTesting(!showSidebar)
                .overlay {
                    if sidebarProgress > 0 {
                        sidebarScrim
                            .opacity(sidebarProgress)
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                            .gesture(sidebarDrag())
                    }
                }
                // 圆角不按 progress 插值:被推开的那张卡从一开始就是整块手机尺寸
                // 的圆角。完全收起时才给 0,免得静止满屏时裁出一圈和真机屏幕遮罩
                // 对不上的角;刚离开 0 那一瞬间卡还基本满屏,44pt 的圆角落在屏幕
                // 自身的遮罩里面,看不出跳变。
                .clipShape(RoundedRectangle(
                    cornerRadius: sidebarProgress > 0 ? DesignMetrics.deviceCornerRadius : 0,
                    style: .continuous))
                // 拖拽/弹簧动画期间这块阴影每帧都要重算,compositingGroup 先把整页
                // 拍平成一张位图再算阴影,不然 SwiftUI 会对一整棵视图树逐层算阴影,
                // 内容一多拖拽就跟不上手、animation 收尾那截也容易掉帧。
                .compositingGroup()
                .shadow(color: .black.opacity(0.18 * sidebarProgress), radius: 14, x: -3)
                // 只平移不缩放:页面保持原大小整块推出去(右侧推出屏幕外),
                // 缩小那版看着像整页被"捏小",不是一张卡被推开的感觉。
                .offset(x: sidebarProgress * DesignMetrics.sidebarWidth)
        }
        // 只对 showSidebar 挂动画:拖拽中 sidebarDragOffset 的变化要 1:1 跟手,
        // 不能被动画平滑掉(松手归位那下由 settleSidebar 里的 withAnimation 负责)。
        .animation(.lodoAware(.lodoSidebar), value: showSidebar)
        // 整个抽屉容器铺到物理屏幕边缘。**必须挂在这一层**,不能只挂在 sectionStack
        // 上:挂在里面时 clipShape 仍按"安全区之内"那个 frame 裁切,推开的卡上下
        // 各短一截、圆角悬在屏幕中间(实测卡内是 249,249,251、上下两截是纯白)。
        // 挂在最外层之后 sectionStack 才拿到整屏的 frame,44pt 圆角落在屏幕真正的
        // 四角上。deviceTopInset 是在 body 的 background 上量的(在这一层之外),
        // 不受影响,侧栏 header 该让开灵动岛还是照让。
        // 只忽略 .container 这一档:默认的 .all 连键盘区一起忽略掉,AI 页输入栏
        // 会被弹起的键盘盖住。
        .ignoresSafeArea(.container)
    }

    /// 宽屏(iPad 横屏、macOS):侧栏常驻并排,同一颗 ☰ 收起/展开,不做推移动画,
    /// 也没有边缘唤出手势(桌面/大屏上靠按钮,不靠边缘滑)。
    private var regularLayout: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebarPanel
                    .frame(width: DesignMetrics.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
                    .transition(.opacity)
            }
            // 同样补页面底色(理由见 compactLayout),但常驻侧栏不推移、不裁圆角,
            // 也就不需要忽略安全区。
            sectionStack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignMetrics.panelBackground(colorScheme))
        }
        .animation(.lodoAware(.lodoSidebar), value: showSidebar)
    }

    // MARK: - 路由交接

    /// 记忆条目左滑"转为待办":切到待办页并弹出预填标题的新建表单。
    private func convertToTodo(_ title: String, _ attachment: TaskAttachment) {
        go(.todo)
        convertToTodoRequest = ConvertToTodoRequest(title: title, attachment: attachment)
    }

    #if os(iOS)
    /// Siri Intent 留下的交接文本(app 冷启动/回前台时消费)。
    private func consumeAgentHandoff() {
        guard let pending = UserDefaults.standard.string(
            forKey: LodoIntentSupport.pendingAgentTextKey) else { return }
        UserDefaults.standard.removeObject(forKey: LodoIntentSupport.pendingAgentTextKey)
        openAgent(prefill: pending)
    }
    #endif

    /// 通知"改期"按钮留下的交接 uuid(app 冷启动/回前台时消费)。
    private func consumeRescheduleHandoff() {
        guard let uuid = UserDefaults.standard.string(
            forKey: NotificationManager.pendingRescheduleUUIDKey) else { return }
        UserDefaults.standard.removeObject(forKey: NotificationManager.pendingRescheduleUUIDKey)
        go(.overview)
        rescheduleRequestUUID = uuid
    }

    #if DEBUG
    /// 截图验证用:simctl 点不了抽屉行,启动参数直接把页面/抽屉摆到位。
    /// 各页面自己那些 --demo-* 参数仍由各页面在 onAppear 里消费,这里只负责
    /// "先切到对的页面",不然那些页面根本没被构建出来。
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        let sectionFlags: [(AppSection, [String])] = [
            (.overview, ["--demo-overview-tab", "--demo-settings", "--demo-reschedule"]),
            (.memory, ["--demo-memory-tab", "--demo-memory-filters", "--demo-seed-memory",
                       "--demo-assets-view", "--demo-contacts-view", "--demo-contact-compose",
                       "--demo-contact-graph", "--demo-contact-detail",
                       "--demo-contact-export-picker"]),
            (.todo, ["--demo-done-tab", "--demo-seed-data", "--demo-filter-all",
                     "--demo-filter-done", "--demo-project-list", "--demo-project-timeline",
                     "--demo-ask-duration", "--demo-convert-to-todo"]),
            (.agent, ["--demo-agent", "--demo-agent-hascontent", "--demo-agent-busy",
                      "--demo-agent-recording", "--demo-easter-egg",
                      "--demo-easter-egg-anniversary", "--demo-agent-quote-preview",
                      "--demo-agent-edit-confirm", "--demo-agent-sidebar"]),
        ]
        for (target, flags) in sectionFlags where flags.contains(where: args.contains) {
            go(target)
            break
        }
        if args.contains("--demo-settings") { showSettings = true }
        // 抽屉本身:simctl 既点不了 ☰ 也滑不了手势,直接摆成展开。
        if args.contains("--demo-sidebar") || args.contains("--demo-agent-sidebar") {
            showSidebar = true
        }
        if args.contains("--demo-convert-to-todo") {
            convertToTodo("测试:从记忆转来的标题", TaskAttachment(
                kind: .text, title: "测试:从记忆转来的标题",
                summary: "这是演示用的记忆摘要,验证附件能正确带进新建表单。",
                text: "演示正文"))
        }
    }
    #endif
}
