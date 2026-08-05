import SwiftUI
import SwiftData
import LodoCore

/// 对话列表面板内容;窄屏抽屉和宽屏常驻侧栏共用同一份视图。参考 Claude iOS 侧栏:
/// 顶部固定「Lodo 衬线体 wordmark + 搜索图标」,中间是「最近 + 对话列表」滚动区,
/// 右下角「新建对话」胶囊是**浮层**——列表内容直接从它下面滚过去(不是布局内的
/// 一行,所以不会把列表挤短,也不加渐隐遮罩,和参考图一致)。
struct AgentThreadListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]
    /// 只为按正文过滤 thread;个人对话历史量级不大,内存里按 threadUUID
    /// 比对字符串就够,不需要引入 FTS5 之类的全文索引。
    @Query private var allMessages: [AgentMessage]

    @Binding var currentThreadUUID: UUID?
    /// 选中/新建一个 thread 后调用,外层用来收起侧栏(窄屏抽屉才需要;宽屏常驻列保持展开)。
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

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearchField {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            List {
                Text("最近")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 6, trailing: 20))
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
                        .frame(minHeight: 48)
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
                    // listRowBackground 铺满整行宽,横向内缩 16 对上参考图高亮块距
                    // 面板边的距离;和上面 24 的文字缩进正好差出那 8pt 留白。
                    .listRowBackground(
                        thread.uuid == effectiveCurrentUUID
                            ? AnyView(RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.09))
                                .padding(.vertical, 2).padding(.horizontal, 16))
                            : AnyView(Color.clear))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 给底部浮层让出高度,最后一条对话仍能滚到浮层上方。
            .contentMargins(.bottom, 84, for: .scrollContent)
        }
        .overlay(alignment: .bottom) { bottomBar }
        .animation(.lodoAware(.lodoQuickFade), value: showSearchField)
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

    /// 底部浮层:右下角主操作"新建对话"胶囊,叠在列表上方,列表内容从它下面滚过。
    /// (设置入口不放这儿,总览 tab 的工具栏里已经有一个。)
    private var bottomBar: some View {
        HStack {
            Spacer()

            Button {
                let thread = AgentThread()
                context.insert(thread)
                try? context.save()
                currentThreadUUID = thread.uuid
                onSelect()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                    .frame(height: 36)
            }
            // 侧栏里唯一的主操作,符合 Liquid Glass "只给独立主操作"的使用边界
            // (旧系统自动回退 .borderedProminent)。
            .glassProminentButton()
            .buttonBorderShape(.capsule)
        }
        .padding(.trailing, 24)
        .padding(.bottom, 28)
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

/// 侧栏顶部那颗搜索圆形图标按钮的样式(不是自绘 UI,只是标准
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
