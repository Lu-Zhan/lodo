import SwiftUI

/// 新系统 API 的门控封装统一收在这个文件里(目前是 iOS 26 的 Liquid Glass,
/// iOS 27 起的新 API 也加在这里):部署目标保持 iOS 17 / macOS 14 不变,新 API
/// 一律 `#available(...)` 运行时门控 + 旧写法回退,**并且把 #available 收进
/// 一个封装**,调用处只写封装名,不在各个视图里重复版本判断。
/// 加 iOS 27 的东西时照抄下面 `glassProminentButton()` 的形状,换成
/// `#available(iOS 27.0, macOS 27.0, *)` 即可;非 UI 的门控(比如健康指标全集)
/// 同理收在各自的一处入口,见 `HealthMetricKind.availableKinds()`。
///
/// iOS 26 / macOS 26 Liquid Glass 按钮样式的门控封装:
/// 新系统用玻璃样式,旧系统回退到 bordered 系列,调用处无需重复 #available。
/// 按 Liquid Glass 设计指引,玻璃样式用于独立操作(如空状态行动按钮、侧栏底部控件),
/// List 行内的重复小按钮仍用 bordered,避免视觉噪声。
extension View {
    /// 独立的次要操作:Liquid Glass 普通玻璃,回退 .bordered。
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// 主要动作:Liquid Glass 高亮玻璃,回退 .borderedProminent。
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// 系统 chrome 用的玻璃材质背景(如 agent 聊天页输入栏),旧系统回退纯色 material。
    /// 同时遵守系统的「减弱透明度」——见 `GlassBackground`。
    func glassBackground(_ shape: some Shape) -> some View {
        modifier(GlassBackground(shape: shape))
    }

    /// 所有页面顶部统一使用柔和的透明模糊渐变，让滚动内容进入导航栏时
    /// 逐渐消隐。修饰符配置整个子树，因此根视图调用一次即可覆盖其中的
    /// List/ScrollView；旧系统保留原有的系统滚动边缘表现。
    @ViewBuilder
    func softTopScrollEdgeTransition() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// `glassBackground` 的实体。之所以是 ViewModifier 而不是直接在 View extension 里
/// 写 `@ViewBuilder if`:要读 `\.accessibilityReduceTransparency` 这个 Environment
/// 值,而 Environment 只能挂在具名的 View/ViewModifier 上;静态读
/// `UIAccessibility.isReduceTransparencyEnabled` 虽然也拿得到,但那样用户在
/// 运行中改设置时视图不会重建,界面要等下一次别的原因刷新才跟上。
///
/// 「减弱透明度」开启时**不做半透明也不做模糊**,直接铺一层不透明面色:
/// 这个开关的用户诉求就是"别让背后的东西透过来影响我读前面的字",把玻璃
/// 换成更厚的材质只是减轻、没有满足它。
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if DesignMetrics.reducesTransparency(reduceTransparency) {
            content.background(DesignMetrics.opaqueSurface, in: shape)
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

/// 表单主要确认按钮:iOS/macOS 26 起用 `role: .confirm` 表达确认语义,
/// 旧系统回退到不带 role 的普通按钮,调用处无需重复 #available。
@ViewBuilder
func confirmButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
        Button(title, role: .confirm, action: action)
    } else {
        Button(title, action: action)
    }
}

extension View {
    /// **相邻的多块玻璃必须共处一个 `GlassEffectContainer`。**玻璃不能采样玻璃:
    /// 各自为政时每块各采一次背景,挨在一起时亮度/折射对不上,看着就不是同一层
    /// 材质;顺带每块玻璃还各建一个 CABackdropLayer(各带 3 张离屏纹理),合进
    /// 一个容器只采一次。
    ///
    /// 只有**彼此挨着**的玻璃需要它:隔着整屏的两块(侧栏顶部搜索键 vs 底部那排)
    /// 不必硬凑一个容器,单独一块玻璃更不需要(理由见 `AgentView.inputBar` 的注释)。
    ///
    /// `spacing` 是**两块玻璃开始互相融合的距离**,不是布局间距——写得比调用处的
    /// 实际间距大,相邻两块就黏成一坨了。默认值刻意取小:只要共享采样,不要融合。
    /// 旧系统没有这个容器,原样透传,调用处不必重复 `#available`。
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 4) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// 列表行"整行一块玻璃"的行背景(侧栏的页面导航行)。和 `glassBackground` 分开是
/// 因为回退不一样:那个退到 `thinMaterial`(小块 chrome 本来就该有个底),行背景
/// 退回去的是**原来那套**——选中的行铺一块浅灰底、没选中的什么都不铺,旧系统上
/// 给每一行都糊一层材质只会让列表变脏。
///
/// 选中态在新系统上靠 `tint` 表达(玻璃本身透,不加色的话选中和没选中只差一点点
/// 反光);旧系统仍是那块浅灰底。「减弱透明度」走回退分支,理由同 `GlassBackground`。
///
/// **偏偏这里不能用 `glassGroup()`**:把整个 List 收进 `GlassEffectContainer` 之后,
/// 行里的图标和文字会被当成玻璃的采样源整个糊掉(实测只剩一排白色圆角块)。
/// "相邻玻璃共用一个容器"那条规矩在列表行上让位:每行各一块玻璃、各建一个
/// backdrop 层是已知代价。另外玻璃要垫在**行内容自己的 `background` 上**,
/// 不能走 `listRowBackground`——那一层画在内容上面,同样会把字糊掉。
struct GlassRowBackground<Fallback: View>: View {
    let selected: Bool
    /// 选中那行的染色(强调色,调用方按 `\.lodoAccent` 传)。
    let tint: Color
    let shape: RoundedRectangle
    @ViewBuilder var fallback: Fallback

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if DesignMetrics.reducesTransparency(reduceTransparency) {
            fallback
        } else if #available(iOS 26.0, macOS 26.0, *) {
            Color.clear
                .glassEffect(selected ? .regular.tint(tint) : .regular, in: shape)
        } else {
            fallback
        }
    }
}

/// 整块面板(侧栏抽屉、AI 右栏)用的玻璃面。和 `glassBackground` 是两个入口:
/// 那个是给输入栏、悬浮条那种小块 chrome 的,旧系统回退到 `thinMaterial`;面板
/// 这边回退要落回 `DesignMetrics.panelBackground`——旧系统上「面板和被推开的
/// 页面卡取同色、只靠投影分层」那套配色还得照旧,退成 thinMaterial 会把那道
/// 刻意做平的边界又拉出来。
///
/// 「减弱透明度」同 `GlassBackground`:不换更厚的材质,直接走 panelBackground
/// 的不透明分支。
struct GlassSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if DesignMetrics.reducesTransparency(reduceTransparency) {
            Rectangle().fill(DesignMetrics.panelBackground(scheme, reduceTransparency: true))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(DesignMetrics.panelBackground(scheme))
        }
    }
}
