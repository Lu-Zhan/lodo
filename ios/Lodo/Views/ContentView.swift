import SwiftUI
import LodoCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppTab = .overview
    /// 非 nil 时由待办页弹出全局 agent 并预填文本(lodo://agent 深链触发,空串=无预填)。
    @State private var agentRequest: String?
    /// tab 栏"添加"按钮触发 agent 时置 true,弹出后自动开始语音(区别于深链/Siri 交接)。
    @State private var agentAutoStart = false
    /// 非 nil 时由总览页跳到该事项并自动发起改期请求(通知"改期"按钮交接)。
    @State private var rescheduleRequestUUID: String?
    /// 非 nil 时由待办页弹出新建表单并预填标题+内容附件(记忆条目"转为待办"交接)。
    @State private var convertToTodoRequest: ConvertToTodoRequest?
    #if DEBUG
    @State private var showAgentSkillsDemo = false
    @State private var showAgentSkillEditDemo = false
    #endif

    enum AppTab: Hashable {
        case overview, todo, memory, add
    }

    /// 上次前台全量重排的时间,30 秒内重复 active 不再触发(避免频繁切换的重排风暴)。
    @State private var lastActiveRefresh = Date.distantPast

    var body: some View {
        tabs
            .onAppear {
                #if DEBUG
                // 截图验证用:已完成已并入待办页底部,保持在待办 tab
                if ProcessInfo.processInfo.arguments.contains("--demo-done-tab") {
                    selection = .todo
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-memory-tab") {
                    selection = .memory
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-overview-tab") {
                    selection = .overview
                }
                // 默认落地页从待办改成总览后,这几个 --demo-* 参数原本靠
                // TodoListView.onAppear 生效,得先把 tab 切过去才挂载得到。
                // (--demo-reschedule/--demo-settings 现在是总览页自己的东西,
                // 总览已是默认 tab,不用切。)
                let todoDemoFlags = [
                    "--demo-agent",
                    "--demo-ask-duration", "--demo-seed-data",
                    "--demo-filter-all", "--demo-filter-done",
                ]
                if todoDemoFlags.contains(where: { ProcessInfo.processInfo.arguments.contains($0) }) {
                    selection = .todo
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-skills") {
                    showAgentSkillsDemo = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-skill-edit") {
                    showAgentSkillEditDemo = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-convert-to-todo") {
                    convertToTodo("测试:从记忆转来的标题", TaskAttachment(
                        kind: .text, title: "测试:从记忆转来的标题",
                        summary: "这是演示用的记忆摘要,验证附件能正确带进新建表单。",
                        text: "演示正文"))
                }
                #endif
            }
            #if DEBUG
            .sheet(isPresented: $showAgentSkillsDemo) {
                NavigationStack { AISettingsView() }
            }
            .sheet(isPresented: $showAgentSkillEditDemo) {
                NavigationStack { AgentSkillEditView(id: .todo) }
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if Date().timeIntervalSince(lastActiveRefresh) > 30 {
                        lastActiveRefresh = Date()
                        Task { @MainActor in NotificationManager.shared.refreshAll() }
                    }
                    #if os(iOS)
                    consumeAgentHandoff()
                    #endif
                    consumeRescheduleHandoff()
                    // Share Extension 落在收件箱的分享内容,回前台时入库整理
                    MemoryPipeline.consumeInbox(context: modelContext)
                }
            }
            #if os(iOS)
            // Siri Intent 交接的快路径(app 已在运行时即时弹出)
            .onReceive(NotificationCenter.default.publisher(
                for: LodoIntentSupport.agentHandoff)) { note in
                UserDefaults.standard.removeObject(
                    forKey: LodoIntentSupport.pendingAgentTextKey)
                selection = .todo
                agentRequest = note.userInfo?["text"] as? String ?? ""
            }
            #endif
            // 通知"改期"按钮交接的快路径(app 已在前台时即时响应)
            .onReceive(NotificationCenter.default.publisher(
                for: NotificationManager.rescheduleHandoff)) { note in
                UserDefaults.standard.removeObject(
                    forKey: NotificationManager.pendingRescheduleUUIDKey)
                selection = .overview
                rescheduleRequestUUID = note.userInfo?["uuid"] as? String
            }
            // 深链:lodo://add(小组件"+")弹全局 agent;lodo://agent?text=…
            // (Siri Intent 回退)弹全局 agent 并预填
            .onOpenURL { url in
                guard url.scheme == "lodo" else { return }
                switch url.host {
                case "add":
                    openAgent(autoStart: true)
                case "agent":
                    let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "text" }?.value
                    selection = .todo
                    agentRequest = text ?? ""
                case "memory":
                    // 分享收藏后从系统分享面板跳回时直达记忆 tab
                    selection = .memory
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // iOS 26+:AI 入口改回系统 Tab(role: .search)的浮动胶囊(见
            // modernTabsWithSearchAI),标签栏随内容下滑收起(仅 iOS)。
            #if os(iOS)
            modernTabsWithSearchAI.tabBarMinimizeBehavior(.onScrollDown)
            #else
            modernTabs
            #endif
        } else if #available(iOS 18.0, macOS 15.0, *) {
            modernTabs
        } else if horizontalSizeClass == .regular {
            // iOS 18 以下没有 sidebarAdaptable(仅 iOS 18+ 才有);宽屏(iPad/旧版 macOS)
            // 手动搭一个 NavigationSplitView 侧边栏,不能让还在用旧系统的 iPad
            // 落到纯 iPhone 式的底部 tab bar。
            legacySidebarTabs
        } else {
            legacyTabs
        }
    }

    /// iOS 18 / macOS 15 起的新 Tab 写法,iOS 18-25 与 macOS 走这条路径。
    /// sidebarAdaptable:iPhone 仍是标签栏,iPad 可展开成侧边栏,macOS 呈现为
    /// 系统「提醒事项」式的侧边栏,是待办类 app 在大屏上的标准形态。
    /// AI 入口(iOS/iPadOS)用叠在 TabView 上的自绘悬浮按钮:短按打开/回到最近
    /// 对话,长按自动开语音——这几个系统版本上 Tab(role: .search) 拿不到长按手势
    /// (系统 tab bar chrome 接管手势,挂不上真正生效的 onLongPressGesture)。
    /// macOS 用的是 TodoListView 工具栏里的"AI 助手"按钮(见该文件),不走这里。
    @available(iOS 18.0, macOS 15.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            Tab("总览", systemImage: "square.stack.3d.up", value: AppTab.overview) {
                OverviewView(rescheduleRequestUUID: $rescheduleRequestUUID)
            }
            Tab("待办", systemImage: "checklist", value: AppTab.todo) {
                TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                            convertToTodoRequest: $convertToTodoRequest)
            }
            Tab("记忆", systemImage: "sparkles.rectangle.stack", value: AppTab.memory) {
                MemoryListView(onConvertToTodo: convertToTodo)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            agentQuickButton
                .padding(.trailing, 20)
                .padding(.bottom, 90)
        }
        #endif
    }

    #if os(iOS)
    /// iOS 26+ 专用:AI 入口用系统 Tab(role: .search)——Liquid Glass 标签栏会把它
    /// 渲成独立于其他标签的浮动胶囊,是系统给"搜索/万能输入"类入口的标准视觉,
    /// 借来承载 AI 助手很贴切。选中这个 tab 不真正停留,onChange 里立刻切回待办
    /// 并弹出 agent;系统 tab bar chrome 接管了手势,这个控件挂不上长按,
    /// 因此不再区分短按/长按,统一按"点击添加自动开始语音"设置项(默认开)决定
    /// 是否自动开语音——这样这个开关的字面意思(点击就开语音)才真的对得上行为。
    @available(iOS 26.0, *)
    private var modernTabsWithSearchAI: some View {
        TabView(selection: $selection) {
            Tab("总览", systemImage: "square.stack.3d.up", value: AppTab.overview) {
                OverviewView(rescheduleRequestUUID: $rescheduleRequestUUID)
            }
            Tab("待办", systemImage: "checklist", value: AppTab.todo) {
                TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                            convertToTodoRequest: $convertToTodoRequest)
            }
            Tab("记忆", systemImage: "sparkles.rectangle.stack", value: AppTab.memory) {
                MemoryListView(onConvertToTodo: convertToTodo)
            }
            Tab("AI 助手", systemImage: "sparkles", value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: selection) { _, newValue in
            if newValue == .add {
                openAgent(autoStart: true)
            }
        }
    }
    #endif

    #if os(iOS)
    /// iOS 18-25 悬浮按钮:短按打开/回到最近一次对话,不自动开语音。长按:同时自动开语音。
    private var agentQuickButton: some View {
        Button {
            openAgent(autoStart: false)
        } label: {
            Image(systemName: "sparkles")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                openAgent(autoStart: true)
            }
        )
        .accessibilityLabel("AI 助手")
        .accessibilityHint("长按直接开始语音")
    }
    #endif

    private func openAgent(autoStart: Bool) {
        selection = .todo
        agentRequest = ""
        agentAutoStart = autoStart
    }

    #if os(iOS)
    /// Siri Intent 留下的交接文本(app 冷启动/回前台时消费):弹 agent 并预填。
    private func consumeAgentHandoff() {
        guard let pending = UserDefaults.standard.string(
            forKey: LodoIntentSupport.pendingAgentTextKey) else { return }
        UserDefaults.standard.removeObject(forKey: LodoIntentSupport.pendingAgentTextKey)
        selection = .todo
        agentRequest = pending
    }
    #endif

    /// 通知"改期"按钮留下的交接 uuid(app 冷启动/回前台时消费)。
    private func consumeRescheduleHandoff() {
        guard let uuid = UserDefaults.standard.string(
            forKey: NotificationManager.pendingRescheduleUUIDKey) else { return }
        UserDefaults.standard.removeObject(forKey: NotificationManager.pendingRescheduleUUIDKey)
        selection = .overview
        rescheduleRequestUUID = uuid
    }

    /// 记忆条目左滑"转为待办":切到待办 tab 并弹出预填标题的新建表单。
    private func convertToTodo(_ title: String, _ attachment: TaskAttachment) {
        selection = .todo
        convertToTodoRequest = ConvertToTodoRequest(title: title, attachment: attachment)
    }

    /// iOS 18 / macOS 15 以下的宽屏侧边栏:手动 NavigationSplitView 代替
    /// sidebarAdaptable(iOS 18+ 才有 API),"设置"仍走 TodoListView 已有的工具栏按钮。
    private var legacySidebarTabs: some View {
        NavigationSplitView {
            // List(selection:) 在 iOS 上只有 Binding<SelectionValue?> 的重载,
            // selection 本身非可选(TabView 等其他地方也在用),这里包一层可选 binding。
            List(selection: Binding<AppTab?>(
                get: { selection },
                set: { if let new = $0 { selection = new } }
            )) {
                Label("总览", systemImage: "square.stack.3d.up").tag(AppTab.overview)
                Label("待办", systemImage: "checklist").tag(AppTab.todo)
                Label("记忆", systemImage: "sparkles.rectangle.stack").tag(AppTab.memory)
            }
            .navigationTitle("lodo")
        } detail: {
            switch selection {
            case .overview:
                OverviewView(rescheduleRequestUUID: $rescheduleRequestUUID)
            case .todo:
                TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                            convertToTodoRequest: $convertToTodoRequest)
            case .memory:
                MemoryListView(onConvertToTodo: convertToTodo)
            case .add:
                Color.clear
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            OverviewView(rescheduleRequestUUID: $rescheduleRequestUUID)
                .tabItem { Label("总览", systemImage: "square.stack.3d.up") }
                .tag(AppTab.overview)
            TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                        convertToTodoRequest: $convertToTodoRequest)
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(AppTab.todo)
            MemoryListView(onConvertToTodo: convertToTodo)
                .tabItem { Label("记忆", systemImage: "sparkles.rectangle.stack") }
                .tag(AppTab.memory)
        }
    }
}
