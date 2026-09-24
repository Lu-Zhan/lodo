import SwiftUI

/// 展示页共用的右下角添加入口。沿用 LiquidGlass.swift 的系统样式门控,
/// 在 iOS/macOS 26 使用高亮玻璃,旧系统使用 borderedProminent。
///
/// **不在这里写 .tint**:原来硬编码了 `.tint(.blue)`,于是它是全 app 唯一
/// 不跟随强调色的主操作——用户在设置里换了颜色,这颗 FAB 还是蓝的。
/// 现在什么都不写,继承 AppShellView 根上下发的那一份。
private struct FloatingAddModifier<Inner: View>: ViewModifier {
    let isVisible: Bool
    /// 存视图值而不是闭包:ViewModifier 要持有它,闭包得标 @escaping,
    /// 而调用处的 @ViewBuilder 参数是非逃逸的。直接求值传进来更省事。
    let inner: Inner
    /// glassProminent 的填充跟 tint 走,但**标签色由系统定,恒为白**——暗色下
    /// 强调色是亮橙,白色「+」压上去对比度只有 2.08,读不清。这里显式指定 onFill。
    @Environment(\.lodoAccent) private var lodoAccent

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isVisible {
                inner
                    .font(.title.weight(.semibold))
                    .foregroundStyle(lodoAccent.onFill)
                    .frame(minWidth: 80, minHeight: 80)
                    .glassProminentButton()
                    .buttonBorderShape(.circle)
                    .tint(lodoAccent.fill)
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
            }
        }
    }
}

extension View {
    func floatingAddAction<Content: View>(
        isVisible: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        modifier(FloatingAddModifier(isVisible: isVisible, inner: content()))
    }
}
