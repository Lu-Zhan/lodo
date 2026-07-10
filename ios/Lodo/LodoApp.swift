import SwiftUI
import SwiftData

@main
struct LodoApp: App {
    let container: ModelContainer

    init() {
        do {
            // 数据库放 App Group,小组件可读;老数据先迁移过去
            if let storeURL = AppGroup.storeURL {
                AppGroup.migrateLegacyStoreIfNeeded(to: storeURL)
                container = try ModelContainer(
                    for: TaskItem.self,
                    configurations: ModelConfiguration(url: storeURL))
            } else {
                container = try ModelContainer(for: TaskItem.self)
            }
        } catch {
            fatalError("无法初始化数据库:\(error)")
        }
        NotificationManager.shared.configure(container: container)
        #if DEBUG
        DemoSeed.populateIfRequested(container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
