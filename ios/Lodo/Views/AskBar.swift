import SwiftUI
import LodoCore

/// 展示页底部那条「问问 AI」对话条:Liquid Glass 胶囊,点一下从底部拉起
/// AI 助手(sheet),输入框自动获得焦点(`AgentView.task` 里那句 isInputFocused),
/// 问完往下一划就回到原来的页面。
///
/// 为什么是"假输入框 + 拉起真页面",而不是就地打字:AI 助手是**单一持续对话**,
/// 回答本身经常是卡片(规划、提案、确认清单)而不是一句话,就地回一行字既放不下
/// 也把上下文丢在了另一个地方。这条只是各页面里离手指最近的那个入口。
///
/// 和右下角 `floatingAddAction` 的分工:「+」是当前页面的新建(记一位人脉、
/// 新建旅行……),这条是"问点别的"。两者都用 `safeAreaInset`/overlay 叠在列表上,
/// 调用顺序是先 `.floatingAddAction`、后 `.askBar()`,FAB 才会落在对话条上方。
private struct AskBarModifier: ViewModifier {
    let isVisible: Bool
    let focus: AgentFocus

    #if DEBUG
    @Environment(\.sectionIsActive) private var sectionIsActive
    #endif

    @State private var showAgent = false
    /// 页面所在那一层的"进到某个条目里"(外壳装的那份)。sheet 里的跳转要先收起
    /// 这一层才看得见目标页面,所以不能直接把它传下去,见下面那份包装。
    @Environment(\.itemNavigator) private var itemNavigator
    /// 递给 AgentHostView 的预填文本。空串 = "只是把页面打开",不覆盖用户上次
    /// 打了一半的内容(语义同外壳的 agentRequest)。
    @State private var prefill: String?
    /// sheet 是独立的呈现宿主,不继承根上那份 .tint(见 SettingsView 同款注释)。
    @AppStorage(AppSettings.accentPaletteKey) private var accentPaletteRaw =
        AppSettings.accentPalette
    private var accentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .terracotta
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    bar
                }
            }
            #if DEBUG
            // 截图验证用:simctl 点不了这条胶囊,启动参数直接把 sheet 拉起来。
            // 只有当前显示的那个页面响应——七个页面叠在 ZStack 里,不筛的话
            // 隐藏页面那几条也会各自要求呈现一次 sheet。
            .onAppear {
                if sectionIsActive,
                   ProcessInfo.processInfo.arguments.contains("--demo-ask-bar") {
                    prefill = ""
                    showAgent = true
                }
            }
            #endif
            .sheet(isPresented: $showAgent) {
                AgentHostView(agentRequest: $prefill, showsCloseButton: true, pageFocus: focus)
                    // 拉起来的这层里不该再有 ☰:抽屉在 sheet **背后**,点了只会
                    // 在看不见的地方推开一扇门。把 chrome 覆盖成 nil,
                    // `sidebarToolbarButton()` 那颗按钮自然不渲染。
                    .environment(\.sidebarChrome, nil)
                    // 跳转小条反过来要留着:点一下**先收起这层 sheet**,再让外壳
                    // 切页面/push——不收的话目标页面就在 sheet 背后打开,用户只
                    // 看见对话原地不动。
                    .environment(\.itemNavigator, itemNavigator.map { outer in
                        ItemNavigator { destination in
                            showAgent = false
                            outer.open(destination)
                        }
                    })
                    .tint(accentPalette.accent)
                    .environment(\.lodoAccent, accentPalette)
                    #if os(iOS)
                    .presentationDragIndicator(.visible)
                    #endif
            }
    }

    private var bar: some View {
        Button {
            prefill = ""
            showAgent = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Text("问问 AI")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            // 和 AI 页面真实输入栏共用同一个高度，两个入口切换时尺寸不跳变。
            .frame(minHeight: DesignMetrics.aiInputHeight)
            .glassBackground(Capsule())
            // 玻璃本身不吃点击,整条胶囊(含 Spacer 那段空白)都要可点。
            .contentShape(Capsule())
        }
        .pressableCard()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityLabel("问问 AI")
        .accessibilityHint("打开 AI 助手")
    }
}

extension View {
    /// 底部「问问 AI」对话条。`isVisible` 控制页面层级(二级页是否显示),
    /// 抽屉展开时输入条跟随页面保留。
    /// `focus` 是所在页面:唤出的 AI 默认把含糊指令当成这一页的事。
    func askBar(focus: AgentFocus, isVisible: Bool = true) -> some View {
        modifier(AskBarModifier(isVisible: isVisible, focus: focus))
    }
}
