import SwiftUI
import SwiftData

@main
struct LodoApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: TaskItem.self)
        } catch {
            fatalError("无法初始化数据库:\(error)")
        }
        NotificationManager.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
