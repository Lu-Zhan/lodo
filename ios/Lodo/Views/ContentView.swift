import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { @MainActor in NotificationManager.shared.refreshAll() }
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
    @available(iOS 18.0, macOS 15.0, *)
    private var modernTabs: some View {
        TabView {
            Tab("待办", systemImage: "checklist") {
                TodoListView()
            }
            Tab("提醒事项", systemImage: "list.bullet.rectangle") {
                RemindersView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }

    private var legacyTabs: some View {
        TabView {
            TodoListView()
                .tabItem { Label("待办", systemImage: "checklist") }
            RemindersView()
                .tabItem { Label("提醒事项", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
