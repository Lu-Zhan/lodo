import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TodoListView()
                .tabItem { Label("待办", systemImage: "checklist") }
            RemindersView()
                .tabItem { Label("提醒事项", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { @MainActor in NotificationManager.shared.refreshAll() }
            }
        }
    }
}
