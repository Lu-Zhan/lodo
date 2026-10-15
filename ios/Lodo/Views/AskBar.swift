import SwiftUI
import LodoCore

/// 展示页底部那条「问问 AI」:和 AI 页**同一条输入栏**(+ | 文本框 + 语音),
/// 点一下就地弹键盘、输入栏跟着抬高——不再拉起整页 AI 助手(2026-10,用户要求)。
/// 发出去之后思考中的轮换词、回答、操作/提问卡片悬浮在输入栏上方,背景透明,
/// 往下一划收起(见 `AgentView.inlineColumn`)。对话本身照旧落进 AI 页那条单一
/// 持续对话,在 AI 页里能看到完整上下文。
///
/// 和右下角 `floatingAddAction` 的分工:「+」是当前页面的新建(记一位人脉、
/// 新建旅行……),这条是"问点别的"。两者都用 `safeAreaInset`/overlay 叠在列表上,
/// 调用顺序是先 `.floatingAddAction`、后 `.askBar()`,FAB 才会落在对话条上方。
private struct AskBarModifier: ViewModifier {
    let isVisible: Bool
    let focus: AgentFocus

    /// 内联模式不用预填(深链/Siri 交接都进侧栏里的 AI 页),给一个恒为 nil 的绑定。
    @State private var prefill: String?
    /// 页面在输入栏上方还剩多高,悬浮内容按它封顶(见 `agentInlineRoom`)。
    @State private var room: CGFloat?
    /// 页面顶部安全区(导航栏 + 状态栏),渐隐底铺到屏幕顶端用。
    @State private var topInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    // geo.size 已经是安全区以内的高度(底部安全区含输入栏本身和键盘),
                    // 再减一次 safeAreaInsets.bottom 会重复扣:键盘一弹起就只剩负数,
                    // 悬浮对话被压到最小 120pt(实测)。
                    let height = geo.size.height
                    let top = geo.safeAreaInsets.top
                    Color.clear
                        .onAppear { room = height; topInset = top }
                        .onChange(of: height) { _, new in room = new }
                        .onChange(of: top) { _, new in topInset = new }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    composer
                        .environment(\.agentInlineRoom, room)
                        .environment(\.agentInlineTopInset, topInset)
                }
            }
    }

    private var composer: some View {
        AgentHostView(agentRequest: $prefill, pageFocus: focus,
                      presentation: .inline, placeholder: focus.askBarPrompt)
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

extension AgentFocus {
    /// 对话条上的那句话:按所在页换成一句贴着这一页的口语短句(菜单页「在吃什么呀？」、
    /// 旅行页「想去哪玩？」),比一句通用的「问问 AI」更像在邀请人开口。
    /// 只是展示文案,不进 prompt——页面焦点另由 `promptBlock` 交给模型。
    /// 日历页刻意不写「哪天有空」:AI 读不到系统日程,那句会让人以为它看得见。
    var askBarPrompt: LocalizedStringKey {
        switch page {
        case .overview: return "今天有什么安排？"
        case .todo: return "要记下什么事？"
        case .calendar: return "要安排点什么？"
        case .countdown: return "还有几天？"
        case .memory: return "想找点什么？"
        case .contact: return "想起谁了？"
        case .assets: return "资产有变化吗？"
        case .health: return "最近身体怎么样？"
        // 旅行详情页带着那次旅行(subject),问的是"这一趟"。
        case .travel: return subject == nil ? "想去哪玩？" : "这趟还想去哪？"
        case .menu: return "在吃什么呀？"
        case .news: return "今天有什么新鲜事？"
        }
    }
}
