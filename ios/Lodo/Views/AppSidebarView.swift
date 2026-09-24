import SwiftUI
import SwiftData
import LodoCore

/// 应用侧栏(导航栏)的面板内容;窄屏抽屉和宽屏常驻列共用同一份视图。
/// 自上而下:「Lodo 衬线体 wordmark」固定头部 → 总览/待办/记忆三个页面导航行
/// (记忆行下面嵌一段记忆标签,常驻的平铺、其余收进"更多标签")→ 健康/旅行/菜单
/// → 底部浮层(左「设置」、右「AI 助手」)。
/// AI 页没有自己的导航行——它就是右下角那颗主操作胶囊,再单列一行只会重复。
/// AI 助手是**单一持续对话**,所以这里既没有对话列表也没有"新建对话":
/// 清空对话的入口在 设置 → AI 设置。
struct AppSidebarView: View {
    /// 记忆标签行的数据源。两个 @Query 的结果直接喂给 MemoryTags.entries 的
    /// 纯内存重载——侧栏在抽屉拖拽期间会被逐帧重建,不能每帧再打两次 fetch。
    @Query private var memoryItems: [MemoryItem]
    @Query private var createdTags: [MemoryTag]

    @Binding var section: AppSection
    /// 点了某个记忆标签行:外层切到记忆页并把这个标签作为筛选条件带过去。
    let onSelectTag: (String) -> Void
    let onOpenSettings: () -> Void
    /// 选中任何一项后调用,外层用来收起侧栏(窄屏抽屉才需要;宽屏常驻列传空实现)。
    let onSelect: () -> Void

    /// 非常驻标签默认折叠,点"更多标签"才展开。
    @State private var showMoreTags = false
    /// 被"常驻"到折叠区外面的标签,换行分隔持久化(顺序即展示顺序)。
    @AppStorage(AppSettings.sidebarPinnedTagsKey) private var pinnedTagsRaw = ""

    // MARK: - 记忆标签

    private var pinnedTags: [String] {
        pinnedTagsRaw.split(separator: "\n").map(String.init)
    }

    /// 全部标签名(按使用条数降序)。这里**不**过滤 hiddenByDefaultTagNames——
    /// 侧栏正是"资产"/"人脉"这两类的快捷入口,和 MemoryListView.allTags 那处
    /// (筛选面板里它们各有独立开关,不跟普通标签混排)是两个不同的用途。
    private var allTagNames: [String] {
        MemoryTags.entries(items: memoryItems, created: createdTags).map(\.name)
    }

    /// 常驻区:按用户"常驻"时的顺序排,已经不存在的标签(条目删光了)自动消失。
    private var visiblePinnedTags: [String] {
        let all = Set(allTagNames)
        return pinnedTags.filter(all.contains)
    }

    /// 折叠区:除去常驻的其余标签。
    private var collapsedTags: [String] {
        let pinned = Set(pinnedTags)
        return allTagNames.filter { !pinned.contains($0) }
    }

    private func togglePin(_ tag: String) {
        var list = pinnedTags
        if let index = list.firstIndex(of: tag) {
            list.remove(at: index)
        } else {
            list.append(tag)
        }
        pinnedTagsRaw = list.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                navRow(.overview, title: "总览", systemImage: "square.stack.3d.up")
                navRow(.todo, title: "待办", systemImage: "checklist")
                navRow(.memory, title: "记忆", systemImage: "sparkles.rectangle.stack")
                pinnedTagRows
                // 健康/旅行/菜单都是建在记忆库上的功能(条目就是打了保留标签的记忆),
                // 放在常驻标签之后、「更多标签」折叠之前:展开折叠时不会被一长串
                // 标签挤到下面去找不着。
                navRow(.health, title: "健康", systemImage: "heart.text.square")
                navRow(.travel, title: "旅行", systemImage: "suitcase.rolling")
                navRow(.menu, title: "菜单", systemImage: "menucard")
                collapsedTagRows

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
        #if DEBUG
        // 截图验证用:simctl 点不了行,直接把"常驻 + 展开折叠区"两态摆出来。
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--demo-sidebar-tags") {
                pinnedTagsRaw = [MemoryItem.assetTagName, "工作"].joined(separator: "\n")
                showMoreTags = true
            }
        }
        #endif
        .animation(.lodoAware(.lodoQuickFade), value: showMoreTags)
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

    /// 六个页面导航行之一,和下面对话历史行同一套样式(行高/内边距/分隔线),
    /// 图标沿用原来三个 tab 的 SF Symbol 保持视觉延续性。当前页面高亮——
    /// 它们是持久态,不像弹层入口那样点完就走。
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
            .frame(minHeight: 40)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(rowHighlight(section == target))
        // 选中态只靠那块浅灰底表达,旁白看不见颜色,得显式给 trait。
        .accessibilityAddTraits(section == target ? .isSelected : [])
    }

    // MARK: - 记忆标签块(嵌在"记忆"行下面)

    @ViewBuilder
    private var pinnedTagRows: some View {
        ForEach(visiblePinnedTags, id: \.self) { tag in
            tagRow(tag, pinned: true)
        }
    }

    @ViewBuilder
    private var collapsedTagRows: some View {
        if !collapsedTags.isEmpty {
            Button {
                showMoreTags.toggle()
            } label: {
                // 和标签行/导航行同一个 Label 结构:图标槽放会转的 chevron,
                // 文字才跟上面几行落在同一条竖线上。
                Label {
                    Text("更多标签")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showMoreTags ? 90 : 0))
                }
                .frame(minHeight: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            if showMoreTags {
                ForEach(collapsedTags, id: \.self) { tag in
                    tagRow(tag, pinned: false)
                }
            }
        }
    }

    /// 标签行的图标。资产/人脉/AI记录 这三个保留标签各自沿用记忆页里已经在用的
    /// 那个符号(筛选开关、"记一笔资产"菜单项、AI 记录条目的行图标),不另挑一套;
    /// 普通标签用通用的 tag,和搜索建议/"管理标签"入口一致。
    private func tagSymbol(_ tag: String) -> String {
        switch tag {
        case MemoryItem.assetTagName: return "creditcard"
        case MemoryItem.contactTagName: return "person.crop.circle"
        case MemoryItem.autoTagName: return "sparkles"
        default: return "tag"
        }
    }

    /// 单个记忆标签行:点进去 = 打开记忆页并按这个标签筛选;左滑切换"常驻"
    /// (常驻的平铺在"记忆"下面,其余收进"更多标签")。缩进和字号都跟导航行一致
    /// ——Label 的图标槽宽度是跟着字号走的,字号一变文字就落不到同一条竖线上了;
    /// 行高比导航行矮一点,标签多的时候不至于把"最近"整个挤下去(再矮就低于
    /// 能稳稳点中的尺寸了,36 是这里的下限)。
    private func tagRow(_ tag: String, pinned: Bool) -> some View {
        Button {
            onSelectTag(tag)
            onSelect()
        } label: {
            HStack {
                Label(tag, systemImage: tagSymbol(tag))
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(minHeight: 36)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button {
                togglePin(tag)
            } label: {
                Label(pinned ? "取消常驻" : "常驻",
                      systemImage: pinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
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

    /// 底部浮层:左下角「设置」(全 app 唯一入口)、右下角主操作「AI 助手」胶囊,
    /// 叠在列表上方,列表内容从它们下面滚过。
    private var bottomBar: some View {
        HStack {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .accessibilityLabel("设置")

            Spacer()

            Button {
                section = .agent
                onSelect()
            } label: {
                Label("AI 助手", systemImage: "sparkles")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 6)
                    // 和左侧齿轮一样以 24pt 内容高度交给系统玻璃样式排版。
                    // 辅助功能字号更大时仍可随内容增高。
                    .frame(minHeight: 24)
            }
            // 侧栏的主操作使用高亮玻璃(旧系统回退 .borderedProminent),
            // 设置是普通玻璃的次要入口。
            .glassProminentButton()
            .buttonBorderShape(.capsule)
            // 它是这份侧栏里 AI 页唯一的入口,所以也要报选中态;胶囊不套
            // rowHighlight(那是给 List 行用的)。
            .accessibilityAddTraits(section == .agent ? .isSelected : [])
            .accessibilityLabel("AI 助手")
        }
        // 这排是全 app 仅有的"两块玻璃挨在同一行"的地方(齿轮 + AI 助手胶囊),
        // 合进一个容器共享采样,免得同一排的两块玻璃亮度对不上。间距取默认的
        // 小值:两颗之间隔着 Spacer,不该融合成一坨。
        .glassGroup()
        .padding(.leading, 20)
        .padding(.trailing, 24)
        // 面板本身已经用 deviceBottomInset 把 home indicator 那截让开了,这里
        // 只再留一点点余量——两个数是叠加的,这里写大了整排按钮会离屏幕底边太远。
        .padding(.bottom, 10)
    }
}
