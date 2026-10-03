import SwiftUI
import SwiftData
import LodoCore

@main
struct LodoApp: App {
    let container: ModelContainer
    #if os(iOS)
    /// 只为挂 scene delegate 接共享邀请(见 `LodoSceneDelegate`)。
    @UIApplicationDelegateAdaptor(LodoAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    /// 接共享邀请、注册远程推送(见 CloudSharingPresenter.swift 里 macOS 那份)。
    @NSApplicationDelegateAdaptor(LodoAppDelegate.self) private var appDelegate
    #endif

    /// 应用内语言开关,不跟随系统语言;和 AppSettings.language 读同一个
    /// UserDefaults key,天然同步(这里是 View 树的隐式解析入口,
    /// AppSettings.language 是非 View 上下文的显式读取入口)。
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    init() {
        // 先开始监听 CloudKit 同步事件再建容器,不然第一次 setup 事件就错过了。
        CloudSyncMonitor.shared.start()
        container = AppDatabase.container
        // 老库里按 thread 分段的对话在这里一次性清掉(见 AgentHistoryMigration)。
        // 放在 DemoSeed 之前:截图用的样板消息是新代码插的,formatVersion 已经是 1,
        // 不会被误删,但顺序上先做迁移更清楚。
        AgentHistoryMigration.run(container: container)
        NotificationManager.shared.configure(container: container)
        // 旅行共享:要在 scene 连上之前配好——冷启动点共享链接进来时,scene delegate
        // 一连上就会调 accept。
        SharedTripSync.shared.configure(container: container)
        #if DEBUG
        DemoSeed.populateIfRequested(container)
        DemoSeed.importBackupIfRequested(container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale)
                .softTopScrollEdgeTransition()
                #if os(macOS)
                // lodo:// 深链(通知、快捷指令、共享邀请)交给已经开着的窗口处理;不写的话
                // macOS 每点一次链接都新开一个窗口。
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Mac 上默认的 regular 控件偏小(「连接日历」「+ 添加」这类主按钮只有一指宽,
                // 用户反馈过);整窗统一放大一档,按钮、选择器、输入框一起变,不逐个调。
                .controlSize(.large)
                #endif
        }
        .modelContainer(container)
        // 定时任务的后台刷新:系统在接近计划时间时给一小段执行时间,跑完直接把
        // 结果推成通知(见 RoutineRunner)。给不给、什么时候给由系统决定,
        // 所以另有到点提醒通知兜底。macOS 没有 .appRefresh 这个后台任务类型
        // (API 本身不可用),那边换成进程内计时器(见 RoutineRunner 的 macTimer)。
        #if os(iOS)
        .backgroundTask(.appRefresh(RoutineRunner.backgroundTaskID)) {
            await RoutineRunner.handleBackgroundRefresh(container: container)
        }
        #elseif os(macOS)
        // 侧栏 + 内容两栏,默认 900×584 的窗口放不下(内容列只剩一半宽)。
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands { LodoCommands() }
        #endif

        #if os(macOS)
        // Mac 的设置是独立窗口(应用菜单「设置…」⌘,),不是 sheet。
        Settings {
            SettingsView(isSettingsWindow: true)
                .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale)
                .controlSize(.large)
        }
        .modelContainer(container)
        #endif
    }
}
