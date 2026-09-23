import SwiftUI
import SwiftData
import LodoCore

@main
struct LodoApp: App {
    let container: ModelContainer

    /// 应用内语言开关,不跟随系统语言;和 AppSettings.language 读同一个
    /// UserDefaults key,天然同步(这里是 View 树的隐式解析入口,
    /// AppSettings.language 是非 View 上下文的显式读取入口)。
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    init() {
        container = AppDatabase.container
        NotificationManager.shared.configure(container: container)
        #if DEBUG
        DemoSeed.populateIfRequested(container)
        DemoSeed.importBackupIfRequested(container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale)
        }
        .modelContainer(container)
        // 定时任务的后台刷新:系统在接近计划时间时给一小段执行时间,跑完直接把
        // 结果推成通知(见 RoutineRunner)。给不给、什么时候给由系统决定,
        // 所以另有到点提醒通知兜底。macOS 没有 .appRefresh 这个后台任务类型
        // (API 本身不可用),那边只靠回前台时的补跑(见 ContentView 的 scenePhase)。
        #if os(iOS)
        .backgroundTask(.appRefresh(RoutineRunner.backgroundTaskID)) {
            await RoutineRunner.handleBackgroundRefresh(container: container)
        }
        #endif
    }
}
