import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .todo
    /// 置 true 时由待办页弹出快速添加页(tab 栏"添加"按钮触发)。
    @State private var addRequested = false

    enum AppTab: Hashable {
        case todo, reminders, add
    }

    var body: some View {
        tabs
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { @MainActor in NotificationManager.shared.refreshAll() }
                }
            }
            // 小组件"+"按钮深链:lodo://add → 切到待办页弹出快速添加
            .onOpenURL { url in
                if url.scheme == "lodo", url.host == "add" {
                    selection = .todo
                    addRequested = true
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
                TodoListView(addRequested: $addRequested)
            }
            Tab("提醒事项", systemImage: "list.bullet.rectangle", value: AppTab.reminders) {
                RemindersView()
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

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            TodoListView(addRequested: $addRequested)
                .tabItem { Label("待办", systemImage: "checklist") }
                .tag(AppTab.todo)
            RemindersView()
                .tabItem { Label("提醒事项", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.reminders)
        }
    }
}
