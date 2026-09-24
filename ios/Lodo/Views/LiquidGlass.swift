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
