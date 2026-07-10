import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .todo
    /// 置 true 时由待办页弹出快速添加页(tab 栏"添加"按钮触发)。
    @State private var addRequested = false
    /// 非 nil 时由待办页弹出全局 agent 并预填文本(lodo://agent 深链触发,空串=无预填)。
    @State private var agentRequest: String?

    enum AppTab: Hashable {
        case todo, done, add
    }

    var body: some View {
        tabs
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { @MainActor in NotificationManager.shared.refreshAll() }
                    #if os(iOS)
                    consumeAgentHandoff()
                    #endif
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
            // 深链:lodo://add(小组件"+")弹快速添加;lodo://agent?text=…
            // (Siri Intent 回退)弹全局 agent 并预填
            .onOpenURL { url in
                guard url.scheme == "lodo" else { return }
                switch url.host {
                case "add":
                    selection = .todo
                    addRequested = true
                case "agent":
                    let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "text" }?.value
                    selection = .todo
                    agentRequest = text ?? ""
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
        } else {
            legacyTabs
        }
    }

    /// iOS 18 / macOS 15 起的新 Tab 写法。
    /// sidebarAdaptable:iPhone 仍是标签栏,iPad 可展开成侧边栏,macOS 呈现为
    /// 系统「提醒事项」式的侧边栏,是待办类 app 在大屏上的标准形态。
    /// iOS 侧第四个 Tab 用 role .search 与前三个分离靠右,作为"添加"按钮:
    /// 选中即拦截,弹出快速添加页并回到原 tab,不真正切换页面。
    @available(iOS 18.0, macOS 15.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            Tab("待办", systemImage: "checklist", value: AppTab.todo) {
                TodoListView(addRequested: $addRequested, agentRequest: $agentRequest)
            }
            Tab("已完成", systemImage: "checkmark.circle", value: AppTab.done) {
                DoneListView()
            }
            #if os(iOS)
            Tab("添加", systemImage: "plus", value: AppTab.add, role: .search) {
                Color.clear
            }
            #endif
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .onChange(of: selection) { _, new in
            if new == .add {
                // "添加"不是真正的页面:切到待办页并弹出快速添加
                selection = .todo
                addRequested = true
            }
        }
        #endif
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

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            TodoListView(addRequested: $addRequested, agentRequest: $agentRequest)
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(AppTab.todo)
            DoneListView()
                .tabItem { Label("已完成", systemImage: "checkmark.circle") }
                .tag(AppTab.done)
        }
    }
}
