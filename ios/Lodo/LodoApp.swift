import SwiftUI
import SwiftData

@main
struct LodoApp: App {
    let container: ModelContainer

    init() {
        container = AppDatabase.container
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
        // 定时任务的后台刷新:系统在接近计划时间时给一小段执行时间,跑完直接把
        // 结果推成通知(见 RoutineRunner)。给不给、什么时候给由系统决定,
        // 所以另有到点提醒通知兜底。
        .backgroundTask(.appRefresh(RoutineRunner.backgroundTaskID)) {
            await RoutineRunner.handleBackgroundRefresh(container: container)
        }
    }
}
