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
/// 按 Liquid Glass 设计指引,玻璃样式只用于独立的主要操作(如空状态的行动按钮),
/// List 行内的重复小按钮仍用 bordered,避免视觉噪声。
extension View {
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
    @ViewBuilder
    func glassBackground(_ shape: some Shape) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.thinMaterial, in: shape)
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
