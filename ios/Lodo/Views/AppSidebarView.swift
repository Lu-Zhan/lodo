import SwiftUI
import SwiftData
import LodoCore

/// 应用侧栏(导航栏)的面板内容;窄屏抽屉和宽屏常驻列共用同一份视图。
/// 自上而下:「Lodo 衬线体 wordmark + 搜索图标」固定头部 → 总览/待办/记忆三个
/// 页面导航行(记忆行下面嵌一段记忆标签,常驻的平铺、其余收进"更多标签")→
/// 「最近」对话历史滚动区 → 底部浮层(左「设置」、右「新建对话」)。
/// AI 页没有自己的导航行——点一条历史对话或「新建对话」就是进 AI 页,
/// 再单列一行只会和它们重复。列表内容直接从底部浮层下面滚过去(不是布局内的
/// 一行,所以不会把列表挤短,也不加渐隐遮罩)。
struct AppSidebarView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]
    /// 只为按正文过滤 thread;个人对话历史量级不大,内存里按 threadUUID
    /// 比对字符串就够,不需要引入 FTS5 之类的全文索引。
    @Query private var allMessages: [AgentMessage]
    /// 记忆标签行的数据源。两个 @Query 的结果直接喂给 MemoryTags.entries 的
    /// 纯内存重载——侧栏在抽屉拖拽期间会被逐帧重建,不能每帧再打两次 fetch。
    @Query private var memoryItems: [MemoryItem]
    @Query private var createdTags: [MemoryTag]

    @Binding var section: AppSection
    @Binding var currentThreadUUID: UUID?
    /// 点了某个记忆标签行:外层切到记忆页并把这个标签作为筛选条件带过去。
    let onSelectTag: (String) -> Void
    let onOpenSettings: () -> Void
    /// 选中任何一项后调用,外层用来收起侧栏(窄屏抽屉才需要;宽屏常驻列传空实现)。
    let onSelect: () -> Void

    /// AgentView 里 currentThreadUUID 为 nil 时会回退到 threads.first,
    /// 这里的"当前"判断要跟那边一致,不然明明在看第一条却没打勾。
    private var effectiveCurrentUUID: UUID? {
        currentThreadUUID ?? threads.first?.uuid
    }

    @State private var pendingDelete: AgentThread?
    @State private var query = ""
    /// 搜索框默认收起,点右上角放大镜才展开——不常驻一整条搜索栏,给列表让出空间。
    @State private var showSearchField = false
    @FocusState private var searchFieldFocused: Bool
    /// 非常驻标签默认折叠,点"更多标签"才展开。
    @State private var showMoreTags = false
    /// 被"常驻"到折叠区外面的标签,换行分隔持久化(顺序即展示顺序)。
    @AppStorage(AppSettings.sidebarPinnedTagsKey) private var pinnedTagsRaw = ""

    /// 标题匹配,或该 thread 下任意一条消息正文匹配。
    private var filteredThreads: [AgentThread] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return threads }
        let matchingThreadUUIDs = Set(
            allMessages.filter { $0.content.localizedStandardContains(trimmed) }.map(\.threadUUID))
        return threads.filter {
            $0.title.localizedStandardContains(trimmed) || matchingThreadUUIDs.contains($0.uuid)
        }
    }

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
            if showSearchField {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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

                Text("最近")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if filteredThreads.isEmpty {
                    Text("没有匹配的对话")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(filteredThreads) { thread in
                    Button {
                        currentThreadUUID = thread.uuid
                        section = .agent
                        onSelect()
                    } label: {
                        HStack {
                            // 字重不随选中态变化:参考图里当前项只靠底色那块圆角浅灰
                            // 区分,字重和其它行一样。
                            Text(thread.title.isEmpty ? "新对话" : thread.title)
                                .font(.body)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .frame(minHeight: 40)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = thread
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowBackground(
                        rowHighlight(section == .agent && thread.uuid == effectiveCurrentUUID))
                    .accessibilityAddTraits(
                        section == .agent && thread.uuid == effectiveCurrentUUID
                            ? .isSelected : [])
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 系统默认最小行高是 44pt,比这里给各行定的 minHeight 还高,不清零的话
            // 行高由它说了算、把 frame(minHeight:) 那几个数字架空。
            .environment(\.defaultMinListRowHeight, 0)
            // 底栏交给安全区,不再 overlay + 写死一个 contentMargins:那样一来
            // 动态字体调大、或者 macOS 换了控件尺寸,底栏比预留的高,最后一条
            // 对话就被压在下面看不见了。safeAreaInset 的视觉效果和 overlay 一样
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
        .animation(.lodoAware(.lodoQuickFade), value: showSearchField)
        .animation(.lodoAware(.lodoQuickFade), value: showMoreTags)
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            "删除这段对话?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let thread = pendingDelete { delete(thread) }
                pendingDelete = nil
            }
        } message: {
            Text("对话记录会一并删除,不可恢复。")
        }
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

    /// 顶部常驻行:左边应用名(参考图那种衬线体 wordmark,仍是系统字体),
    /// 右边放大镜图标按钮(点了才展开下面那条搜索框)。
    private var header: some View {
        HStack {
            Text("Lodo")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
            Spacer()
            Button {
                showSearchField.toggle()
                if showSearchField {
                    searchFieldFocused = true
                } else {
                    query = ""
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(SidebarIconButtonStyle())
            .accessibilityLabel("搜索对话")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }

    /// 底部浮层:左下角「设置」(全 app 唯一入口)、右下角主操作「新建对话」胶囊,
    /// 叠在列表上方,列表内容从它们下面滚过。
    private var bottomBar: some View {
        HStack {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(SidebarIconButtonStyle())
            // 这颗浮在列表上方,底下要垫一层不透明底色——SidebarIconButtonStyle
            // 那圈浅灰是半透明的,不垫的话最后一条对话的文字会从圆钮里透出来。
            // 垫的必须是面板自己的底色,不能是 .background(纯白):面板是分组灰,
            // 白圆底会在上面显成一个白点。右边"新建对话"胶囊本身不透明,不需要这层。
            .background(Circle().fill(DesignMetrics.panelBackground(colorScheme)))
            .accessibilityLabel("设置")

            Spacer()

            Button {
                let thread = AgentThread()
                context.insert(thread)
                try? context.save()
                currentThreadUUID = thread.uuid
                section = .agent
                onSelect()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                    // 最小高度而不是固定高度:辅助功能字号下这行字会换行/变高,
                    // 写死 36 会把它硬裁掉。
                    .frame(minHeight: 36)
            }
            // 侧栏里唯一的主操作,符合 Liquid Glass "只给独立主操作"的使用边界
            // (旧系统自动回退 .borderedProminent)。设置那颗是次要入口,保持低调
            // 的圆形图标钮,不跟它抢。
            .glassProminentButton()
            .buttonBorderShape(.capsule)
        }
        .padding(.leading, 20)
        .padding(.trailing, 24)
        // 面板本身已经用 deviceBottomInset 把 home indicator 那截让开了,这里
        // 只再留一点点余量——两个数是叠加的,这里写大了整排按钮会离屏幕底边太远。
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.footnote)
            TextField("搜索对话", text: $query)
                .textFieldStyle(.plain)
                .font(.footnote)
                .focused($searchFieldFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// 连带删掉这个 thread 下的全部消息,避免孤儿数据。
    private func delete(_ thread: AgentThread) {
        let uuid = thread.uuid
        let messages = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate { $0.threadUUID == uuid }))) ?? []
        for message in messages { context.delete(message) }
        if currentThreadUUID == uuid { currentThreadUUID = nil }
        context.delete(thread)
        try? context.save()
    }
}

/// 侧栏那几颗圆形图标按钮(顶部搜索、底部设置)的样式(不是自绘 UI,只是标准
/// ButtonStyle 协议):44×44 圆底(对齐参考图里圆钮的直径)+ 按下加深。
/// 底色用 `Color.primary.opacity` 而不是
/// 语义的 `.fill.tertiary`——后者本身太淡,在面板这种纯背景色上几乎显不出来
/// (thread 行的选中态高亮当初就是踩了这个坑才换的写法)。
private struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
    }
}
