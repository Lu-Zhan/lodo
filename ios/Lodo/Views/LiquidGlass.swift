import SwiftUI

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
}
