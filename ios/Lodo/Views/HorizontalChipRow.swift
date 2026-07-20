import SwiftUI

/// 横向可滑动选项行的公共外壳:改期候选、耗时采样 chips、agent 反问候选共用,
/// 调用处只需提供各自的按钮内容。
struct HorizontalChipRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                content()
            }
        }
    }
}
