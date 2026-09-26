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

private struct SectionIsActiveKey: EnvironmentKey {
    /// 默认 true:表单、sheet 之类不在页面 ZStack 里的地方按「正在显示」处理。
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 当前视图所属的页面是不是正在显示的那个。由 `AppShellView` 逐页下发。
    var sectionIsActive: Bool {
        get { self[SectionIsActiveKey.self] }
        set { self[SectionIsActiveKey.self] = newValue }
    }
}
