import SwiftUI

/// 展示页共用的右下角添加入口。沿用 LiquidGlass.swift 的系统样式门控，
/// 在 iOS/macOS 26 使用高亮玻璃，旧系统使用蓝色 borderedProminent。
extension View {
    func floatingAddAction<Content: View>(
        isVisible: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if isVisible {
                content()
                    .font(.title.weight(.semibold))
                    .frame(minWidth: 80, minHeight: 80)
                    .glassProminentButton()
                    .buttonBorderShape(.circle)
                    .tint(.blue)
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
            }
        }
    }
}
