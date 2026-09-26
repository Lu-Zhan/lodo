import SwiftUI

/// 应用侧栏(导航栏)的面板内容;窄屏抽屉和宽屏常驻列共用同一份视图。
/// 自上而下:「Lodo 衬线体 wordmark」固定头部 → 总览/任务/日历/记忆四个页面导航行
/// → 人脉/健康/旅行/菜单/AI 助手 → 底部浮层「设置」玻璃圆。
/// AI 助手是**单一持续对话**,所以这里既没有对话列表也没有"新建对话":
/// 清空对话的入口在 设置 → AI 设置。
///
/// **记忆标签行已整个去掉**(2026-09):标签平铺 + 左滑常驻那一套原本是记忆页
/// 按标签筛选的唯一入口,但侧栏是导航,标签越攒越多就把下面的功能行挤下去;
/// 找东西现在一律靠各页底下那条「问问 AI」(语义检索本来也只在 AI 那边)。
/// 标签本身还在(记忆条目照常带标签、记忆页右上角仍有「管理标签」),只是
/// 没有"按标签筛选"这个入口了。
struct AppSidebarView: View {
    let section: AppSection
    let onOpenSettings: () -> Void
    /// 外层先切到目标页面,再收起窄屏抽屉。
    let onSelect: (AppSection) -> Void

    @Environment(\.lodoAccent) private var lodoAccent

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                navRow(.overview, title: "总览", systemImage: "square.stack.3d.up")
                navRow(.todo, title: "任务", systemImage: "checklist")
                navRow(.calendar, title: "日历", systemImage: "calendar")
                navRow(.memory, title: "记忆", systemImage: "sparkles.rectangle.stack")
                // 人脉/健康/旅行/菜单都是建在记忆库上的功能,紧跟在记忆行后面。
                navRow(.contact, title: "人脉", systemImage: "person.crop.circle")
                navRow(.health, title: "健康", systemImage: "heart.text.square")
                navRow(.travel, title: "旅行", systemImage: "suitcase.rolling")
                navRow(.menu, title: "菜单", systemImage: "menucard")
                // AI 助手也是个平级页面,排在最后一行;图标常驻主题色——
                // 它是这一排里唯一带色的图标,一眼能找到(见 navRow 的 tinted)。
                navRow(.agent, title: "AI 助手", systemImage: "sparkles", tinted: true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // **这个 List 不能塞进 `glassGroup()`(GlassEffectContainer)**:实测
            // (iOS 27 模拟器)整排行的图标和文字会被当成玻璃的采样源整个糊掉,
            // 只剩八块白色圆角。相邻玻璃共用容器那条规矩在这里让位——八行各自
            // 一块玻璃、各建一个 backdrop 层是已知代价,换的是行还看得见。
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

    /// 导航行的行背景。新系统每行一块 Liquid Glass(选中那行染强调色),旧系统 /
    /// 「减弱透明度」退回原来那套:选中的一块圆角浅灰底,没选中的什么都不铺。
    /// 版本判断收在 `GlassRowBackground` 里,这里只写形状和回退长什么样。
    ///
    /// 玻璃块铺满整行宽、横向内缩 16 对上参考图里高亮块距面板边的距离;
    /// 和行文字 24 的缩进正好差出那 8pt 留白。
    private func rowBackground(_ selected: Bool) -> some View {
        GlassRowBackground(
            selected: selected,
            // 透明的玻璃上染色要压得很淡:满色会盖住背后的内容,那就不是玻璃了。
            tint: lodoAccent.accent.opacity(0.28),
            shape: RoundedRectangle(cornerRadius: DesignMetrics.sidebarRowRadius, style: .continuous)
        ) {
            rowHighlight(selected)
        }
    }

    /// 旧系统上的选中底(也是「减弱透明度」时的样子)。
    @ViewBuilder
    private func rowHighlight(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: DesignMetrics.sidebarRowRadius, style: .continuous)
                .fill(Color.primary.opacity(0.09))
        } else {
            Color.clear
        }
    }

    /// 页面导航行之一,图标沿用原来三个 tab 的 SF Symbol 保持视觉延续性。
    /// 当前页面高亮——它们是持久态,不像弹层入口那样点完就走。
    /// `tinted` 的行图标常驻主题色(只有 AI 助手那行)。标题类型是 `LocalizedStringKey`
    /// 而不是 `String`:传 String 会走 `Label` 的 StringProtocol 重载,那条**不查
    /// 本地化表**,英文界面下这七八行会全是中文。
    private func navRow(_ target: AppSection, title: LocalizedStringKey, systemImage: String,
                        tinted: Bool = false) -> some View {
        Button {
            onSelect(target)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tinted ? AnyShapeStyle(lodoAccent.accent)
                                            : AnyShapeStyle(.primary))
                    .font(.body)
                    // 图标按最宽的那个对齐,不然每行文字的起点会随图标宽度跳。
                    .frame(width: Self.rowIconWidth, alignment: .center)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    // 面板只有屏幕三分之一宽,英文标题("AI Assistant""Overview")
                    // 在里面放不下。**这里不用 `Label` + `Spacer`**:实测那种写法下
                    // minimumScaleFactor 落不到实处(挂在 Text 上、挂在 Label 上、
                    // 再加 layoutPriority 都试过),一律截成「Overvi…」;拆成
                    // Image + Text、用 frame(maxWidth:) 顶开而不是拿 Spacer 占位,
                    // 缩放才有机会生效。**英文界面的效果还没截图核过**(改完这轮
                    // 模拟器拒绝启动 app),中文界面两字标题本来就放得下。
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 玻璃垫在**行内容自己的 background 上**,不走 `listRowBackground`:
            // 那一层是画在内容**上面**的,玻璃会把这一行的图标和文字整个糊掉
            // (实测整排行只剩白色圆角块,字一个都看不见)。
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(minHeight: DesignMetrics.aiInputHeight)
            .background { rowBackground(section == target) }
            // 玻璃本身不吃点击,整行(含文字右边那段空白)都要可点。
            .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.sidebarRowRadius,
                                           style: .continuous))
        }
        // 行内容自己带了 8/4 的内边距,这里从 24/20 收到 16/16,文字位置不变、
        // 玻璃块两边各留 16 —— 和原来那块浅灰高亮底的位置一致。
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // 选中态只靠那块染色玻璃(旧系统是浅灰底)表达,旁白看不见颜色,
        // 得显式给 trait。
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
                // 窄屏面板只有屏幕三分之一宽,largeTitle 的 wordmark 正好顶到
                // 两边内边距;宁可缩一点也不能截成「Lod…」。
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
    }

    /// 底部浮层:左对齐的「设置」一颗玻璃圆(全 app 唯一设置入口),叠在列表上方、
    /// 列表内容从它下面滚过。
    ///
    /// 「AI 助手」原来挨在它右边,2026-09 回到列表里当最后一行(排在「菜单」后面):
    /// 它是个**页面**,和上面七个平级,摆在底部浮层里看着像个和「设置」同级的工具
    /// 入口。底下只剩一颗玻璃,单独一块不需要 `glassGroup()`。
    private var bottomBar: some View {
        HStack(spacing: Self.bottomBarSpacing) {
            circleButton(systemImage: "gearshape", label: "设置", selected: false) {
                onOpenSettings()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.bottomBarInset)
        // 面板本身已经用 deviceBottomInset 把 home indicator 那截让开了,这里
        // 只再留一点点余量——两个数是叠加的,这里写大了按钮会离屏幕底边太远。
        .padding(.bottom, 10)
    }

    /// 导航行图标的固定宽度:SF Symbol 各自宽度不一,不定死的话每行文字起点会错开。
    private static let rowIconWidth: CGFloat = 22

    private static let bottomBarSpacing: CGFloat = 8
    private static let bottomBarInset: CGFloat = 12

    /// 底栏那颗玻璃圆的尺寸。aiInputHeight(48)本来就过 HIG 的 44,不需要
    /// `hitTarget(visualSize:)`;只有一颗,窄到屏幕三分之一的面板也放得下。
    private var controlSize: CGFloat { DesignMetrics.aiInputHeight }

    private func circleButton(systemImage: String,
                              label: LocalizedStringKey,
                              selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(selected ? lodoAccent.accent : .primary)
                .frame(width: controlSize, height: controlSize)
                .glassBackground(Circle())
                .contentShape(Circle())
        }
        .pressable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
