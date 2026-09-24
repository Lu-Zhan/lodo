import SwiftUI
import LodoCore

/// 最外层:导航外壳(`AppShellView`,四个平级页面 + 左滑抽屉)+ 首次引导,
/// 再加上几件和导航无关、必须挂在整个 app 上的前台副作用(提醒重排、定时任务
/// 补跑、Share 收件箱)。页面切换、深链、Siri/通知交接这些属于导航的事都在
/// `AppShellView` 里,这里不再插手。
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppSettings.hasSeenOnboardingKey) private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    #if DEBUG
    @State private var showAgentSkillsDemo = false
    @State private var showAgentSkillEditDemo = false
    @State private var showRoutinesDemo = false
    @State private var showRoutineEditDemo = false
    #endif

    /// 上次前台全量重排的时间,30 秒内重复 active 不再触发(避免频繁切换的重排风暴)。
    @State private var lastActiveRefresh = Date.distantPast

    /// 以前这里把系统字号整体顶高一档(`appTypeSize`)。那是在给"内容样式整体
    /// 偏小一档"打补丁——列表主标题当时是 `.subheadline`(15pt),比 Apple 自家
    /// 列表行低一到两档,于是在根上把所有东西一起放大。副作用是**导航栏标题和
    /// 分区标题也跟着放大**,而这两处本来就是对的,结果分区标题比它统领的内容
    /// 还醒目,层级是反的(总览页尤其明显)。
    ///
    /// 现在把内容样式整体上移了一档(subheadline→body、footnote→subheadline、
    /// caption→footnote、caption2→caption,共 206 处),内容的视觉尺寸和之前
    /// 基本持平,所以这层全局补偿可以撤掉,chrome 回到平台正确的尺寸。
    /// **别再加回来**——要调内容大小就改文字角色本身。
    var body: some View {
        AppShellView()
            .onAppear {
                if !hasSeenOnboarding {
                    showOnboarding = true
                }
                #if DEBUG
                // 截图验证用:测试其余 --demo-* 场景时不想被首次引导挡住。
                if ProcessInfo.processInfo.arguments.contains("--demo-skip-onboarding") {
                    showOnboarding = false
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-skills") {
                    showAgentSkillsDemo = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-skill-edit") {
                    showAgentSkillEditDemo = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-routines") {
                    showRoutinesDemo = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-routine-edit") {
                    showRoutineEditDemo = true
                }
                #endif
            }
            #if DEBUG
            .sheet(isPresented: $showAgentSkillsDemo) {
                NavigationStack { AISettingsView() }
            }
            .sheet(isPresented: $showAgentSkillEditDemo) {
                NavigationStack { AgentSkillEditView(id: .todo) }
            }
            .sheet(isPresented: $showRoutinesDemo) {
                NavigationStack { RoutineListView() }
            }
            .sheet(isPresented: $showRoutineEditDemo) {
                // 天气穿搭模板(联网那条),新建态
                RoutineEditView(routine: AIRoutine(preset: AIRoutine.presets[1]), isNew: true)
            }
            #endif
            // macOS 没有 fullScreenCover(API 本身就不可用),用窗口 sheet 代替。
            #if os(iOS)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { showOnboarding = false })
            }
            #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { showOnboarding = false })
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if Date().timeIntervalSince(lastActiveRefresh) > 30 {
                        lastActiveRefresh = Date()
                        Task { @MainActor in NotificationManager.shared.refreshAll() }
                    }
                    // 定时任务补跑:后台刷新没赶上时(系统不保证唤醒),回前台立刻
                    // 把错过的槽位跑掉。人已经在 app 里了,结果直接显示,不推通知。
                    // 不放进上面的 30 秒节流里——判断本身只是一次取数据加比较,
                    // 而漏掉一次到点触发要等下一次激活才补。
                    Task { @MainActor in
                        await RoutineRunner.runDueRoutines(context: modelContext,
                                                           notifyResults: false)
                    }
                    // Share Extension 落在收件箱的分享内容,回前台时入库整理
                    MemoryPipeline.consumeInbox(context: modelContext)
                }
            }
    }
}
