import SwiftUI

/// 横向可滑动选项行的公共外壳:改期候选、耗时采样 chips、agent 反问候选共用,
/// 调用处只需提供各自的按钮内容。
///
/// 它同时向外层抽屉(`AppShellView`)申报自己的位置:整页任意位置往右拖都会
/// 唤出抽屉,而这一行本身就是横向滚动的,不打招呼的话"往右看下一个胶囊"会
/// 顺手把抽屉一起拖出来。落在申报矩形里起手的拖拽,抽屉直接不接管。
struct HorizontalChipRow<Content: View>: View {
    @Environment(\.sectionIsActive) private var sectionIsActive
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                content()
            }
        }
        // 只有当前显示的那个页面才申报。四个页面是叠在 ZStack 里的(不显示的
        // 那几个只是 opacity 0,仍然在布局、仍然会往上冒 preference),不筛的话
        // 记忆页顶部会莫名其妙多出一块"拖不出抽屉"的死区——那是待办页的胶囊行
        // 叠在同一个位置上。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDragExclusionKey.self,
                    value: sectionIsActive
                        ? [proxy.frame(in: .named(SidebarDragExclusion.spaceName))]
                        : [])
            }
        )
    }
}

// MARK: - 抽屉手势排除区

enum SidebarDragExclusion {
    /// 页面容器的具名坐标空间。抽屉手势的 startLocation 和这里申报的矩形都换算
    /// 到这个空间里,才能直接比对。
    static let spaceName = "lodo.sectionStack"
}

struct SidebarDragExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct SectionIsActiveKey: EnvironmentKey {
    /// 默认 true:表单、sheet 之类不在页面 ZStack 里的地方照常申报。
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 当前视图所属的页面是不是正在显示的那个。由 `AppShellView` 逐页下发。
    var sectionIsActive: Bool {
        get { self[SectionIsActiveKey.self] }
        set { self[SectionIsActiveKey.self] = newValue }
    }
}
