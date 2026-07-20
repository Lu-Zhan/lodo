import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppTab = .todo
    /// 非 nil 时由待办页弹出全局 agent 并预填文本(lodo://agent 深链触发,空串=无预填)。
    @State private var agentRequest: String?
    /// tab 栏"添加"按钮触发 agent 时置 true,弹出后自动开始语音(区别于深链/Siri 交接)。
    @State private var agentAutoStart = false
    /// 非 nil 时由待办页跳到该事项并自动发起改期请求(通知"改期"按钮交接)。
    @State private var rescheduleRequestUUID: String?

    enum AppTab: Hashable {
        case todo, memory, add
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
                #endif
            }
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
                selection = .todo
                rescheduleRequestUUID = note.userInfo?["uuid"] as? String
            }
            // 深链:lodo://add(小组件"+")弹全局 agent;lodo://agent?text=…
            // (Siri Intent 回退)弹全局 agent 并预填
            .onOpenURL { url in
                guard url.scheme == "lodo" else { return }
                switch url.host {
                case "add":
                    selection = .todo
                    agentRequest = ""
                    agentAutoStart = true
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
            // iOS 26+:Liquid Glass 标签栏随内容下滑收起(仅 iOS)
            #if os(iOS)
            modernTabs.tabBarMinimizeBehavior(.onScrollDown)
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

    /// iOS 18 / macOS 15 起的新 Tab 写法。
    /// sidebarAdaptable:iPhone 仍是标签栏,iPad 可展开成侧边栏,macOS 呈现为
    /// 系统「提醒事项」式的侧边栏,是待办类 app 在大屏上的标准形态。
    /// iOS 侧第四个 Tab 用 role .search 与前三个分离靠右,作为"添加"按钮:
    /// 选中即拦截,弹出 AI 助手并回到原 tab,不真正切换页面。
    @available(iOS 18.0, macOS 15.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            Tab("待办", systemImage: "checklist", value: AppTab.todo) {
                TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                            rescheduleRequestUUID: $rescheduleRequestUUID)
            }
            Tab("记忆", systemImage: "sparkles.rectangle.stack", value: AppTab.memory) {
                MemoryListView()
            }
            Tab("添加", systemImage: "plus", value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: selection) { _, new in
            if new == .add {
                // "添加"不是真正的页面:切到待办页并弹出 AI 助手(自动开始语音)
                selection = .todo
                agentRequest = ""
                agentAutoStart = true
            }
        }
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
        selection = .todo
        rescheduleRequestUUID = uuid
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
                Label("待办", systemImage: "checklist").tag(AppTab.todo)
                Label("记忆", systemImage: "sparkles.rectangle.stack").tag(AppTab.memory)
            }
            .navigationTitle("lodo")
        } detail: {
            switch selection {
            case .todo:
                TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                            rescheduleRequestUUID: $rescheduleRequestUUID)
            case .memory:
                MemoryListView()
            case .add:
                Color.clear
            }
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            TodoListView(agentRequest: $agentRequest, agentAutoStart: $agentAutoStart,
                        rescheduleRequestUUID: $rescheduleRequestUUID)
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(AppTab.todo)
            MemoryListView()
                .tabItem { Label("记忆", systemImage: "sparkles.rectangle.stack") }
                .tag(AppTab.memory)
        }
    }
}
