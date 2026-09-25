import SwiftUI

/// 应用侧栏(导航栏)的面板内容;窄屏抽屉和宽屏常驻列共用同一份视图。
/// 自上而下:「Lodo 衬线体 wordmark」固定头部 → 总览/任务/记忆三个页面导航行
/// → 人脉/健康/旅行/菜单 → 底部浮层「设置」+「AI 助手」两颗玻璃圆。
/// AI 助手是**单一持续对话**,所以这里既没有对话列表也没有"新建对话":
/// 清空对话的入口在 设置 → AI 设置。
///
/// **记忆标签行已整个去掉**(2026-09):标签平铺 + 左滑常驻那一套原本是记忆页
/// 按标签筛选的唯一入口,但侧栏是导航,标签越攒越多就把下面的功能行挤下去;
/// 找东西现在一律靠各页底下那条「问问 AI」(语义检索本来也只在 AI 那边)。
/// 标签本身还在(记忆条目照常带标签、记忆页右上角仍有「管理标签」),只是
/// 没有"按标签筛选"这个入口了。
struct AppSidebarView: View {
    @Binding var section: AppSection
    let onOpenSettings: () -> Void
    /// 选中任何一项后调用,外层用来收起侧栏(窄屏抽屉才需要;宽屏常驻列传空实现)。
    let onSelect: () -> Void

    @Environment(\.lodoAccent) private var lodoAccent

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                navRow(.overview, title: "总览", systemImage: "square.stack.3d.up")
                navRow(.todo, title: "任务", systemImage: "checklist")
                navRow(.memory, title: "记忆", systemImage: "sparkles.rectangle.stack")
                // 人脉/健康/旅行/菜单都是建在记忆库上的功能,紧跟在记忆行后面。
                navRow(.contact, title: "人脉", systemImage: "person.crop.circle")
                navRow(.health, title: "健康", systemImage: "heart.text.square")
                navRow(.travel, title: "旅行", systemImage: "suitcase.rolling")
                navRow(.menu, title: "菜单", systemImage: "menucard")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 系统默认最小行高是 44pt,比这里给各行定的 minHeight 还高,不清零的话
            // 行高由它说了算、把 frame(minHeight:) 那几个数字架空。
            .environment(\.defaultMinListRowHeight, 0)
            // 底栏交给安全区,不再 overlay + 写死一个 contentMargins:那样一来
            // 动态字体调大、或者 macOS 换了控件尺寸,底栏比预留的高,最后一行
            // 就被压在下面看不见了。safeAreaInset 的视觉效果和 overlay 一样
            // (列表照样从它背后滚过去),但让出的高度是量出来的。
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .frame(maxHeight: .infinity)
    }

    /// 行选中态的那块圆角浅灰底。铺满整行宽、横向内缩 16 对上参考图里高亮块
    /// 距面板边的距离;和行文字 24 的缩进正好差出那 8pt 留白。
    @ViewBuilder
    private func rowHighlight(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.09))
                .padding(.vertical, 2).padding(.horizontal, 16)
        } else {
            Color.clear
        }
    }

    /// 页面导航行之一,图标沿用原来三个 tab 的 SF Symbol 保持视觉延续性。
    /// 当前页面高亮——它们是持久态,不像弹层入口那样点完就走。
    private func navRow(_ target: AppSection, title: String, systemImage: String) -> some View {
        Button {
            section = target
            onSelect()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(minHeight: DesignMetrics.aiInputHeight)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(rowHighlight(section == target))
        // 选中态只靠那块浅灰底表达,旁白看不见颜色,得显式给 trait。
        .accessibilityAddTraits(section == target ? .isSelected : [])
    }

    /// 顶部常驻行:只有应用名(参考图那种衬线体 wordmark,仍是系统字体)。
    /// 右边原来那颗放大镜是用来在多个对话之间找对话的,单一持续对话下没有
    /// 对象可找,连同搜索框一起去掉了;右内边距跟着从 16 调回 20——那 16 是
    /// 给玻璃圆按钮留的视觉补偿,按钮没了会显得右边比左边窄。
    private var header: some View {
        HStack {
            Text("Lodo")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            Spacer()
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
    }

    /// 底部浮层:左对齐的「设置」(全 app 唯一入口)+ 紧挨着右边的「AI 助手」,
    /// 两颗同尺寸玻璃圆,叠在列表上方、列表内容从它下面滚过。
    /// AI 助手原来是列表里的一行,挪到这里是因为它和设置一样属于"常在手边"的
    /// 入口,不该跟着页面列表往下滚。
    ///
    /// 两颗玻璃**挨着**,所以整条收进一个 `glassGroup()`:玻璃采样不到玻璃,
    /// 各自为政时两块的亮度/折射对不上,还各建一个 CABackdropLayer。
    private var bottomBar: some View {
        HStack(spacing: 10) {
            circleButton(systemImage: "gearshape", label: "设置", selected: false) {
                onOpenSettings()
            }
            // AI 助手是个页面,所以和导航行一样表达选中态:侧栏行靠浅灰底,
            // 这里没有行背景可用,改成图标染成强调色。
            circleButton(systemImage: "sparkles", label: "AI 助手",
                         selected: section == .agent) {
                section = .agent
                onSelect()
            }
            Spacer()
        }
        .glassGroup()
        .padding(.horizontal, 16)
        // 面板本身已经用 deviceBottomInset 把 home indicator 那截让开了,这里
        // 只再留一点点余量——两个数是叠加的,这里写大了按钮会离屏幕底边太远。
        .padding(.bottom, 10)
    }

    /// 底栏那两颗玻璃圆。尺寸取 aiInputHeight(48),本来就过 HIG 的 44,
    /// 不需要 `hitTarget(visualSize:)`。
    private func circleButton(systemImage: String,
                              label: LocalizedStringKey,
                              selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(selected ? lodoAccent.accent : .primary)
                .frame(width: DesignMetrics.aiInputHeight, height: DesignMetrics.aiInputHeight)
                .glassBackground(Circle())
                .contentShape(Circle())
        }
        .pressable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
