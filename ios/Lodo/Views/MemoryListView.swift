import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import LodoCore
#if os(iOS)
import UIKit
#endif

/// "记忆" tab:AI 整理后的收藏条目列表。顶部搜索框输入即本地过滤 + 标签筛选;
/// 自然语言问答统一走右下角全局 agent 入口(TodoListView+Agent.answerFromMemory)。
struct MemoryListView: View {
    /// 左滑"转为待办"交接:切到待办 tab 并弹出预填标题+内容附件的新建表单(见 ContentView)。
    let onConvertToTodo: (String, TaskAttachment) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var items: [MemoryItem]
    /// 只为让标签行随"用户创建标签"变化刷新;全集经 MemoryTags 汇总。
    @Query private var createdTags: [MemoryTag]

    @State private var query = ""
    @State private var selectedTags: Set<String> = []
    @State private var selectedKinds: Set<MemoryKind> = []
    @State private var showAssets = false
    @State private var showFilters = false
    @State private var showCompose = false
    @State private var showAssetCompose = false
    @State private var showFileImporter = false
    @State private var showTagManage = false
    @State private var pendingDelete: MemoryItem?

    /// 普通内容标签(不含"资产"这个保留标签——它有自己独立的筛选开关,
    /// 不跟其他标签混在一起,更醒目也避免用户把它当成普通标签删掉)。
    private var allTags: [String] {
        MemoryTags.all(in: context).filter { $0 != MemoryItem.assetTagName }
    }

    /// 出现过的来源格式,按固定顺序(与内容标签是两套独立的筛选)。
    private var availableKinds: [MemoryKind] {
        let present = Set(items.map(\.kind))
        return [MemoryKind.text, .link, .pdf, .image, .file].filter(present.contains)
    }

    private var activeFilterCount: Int {
        selectedTags.count + selectedKinds.count + (showAssets ? 1 : 0)
    }

    /// 文字过滤、格式筛选、标签筛选取交集;格式内部是"任一命中"
    /// (一条只有一种格式),标签内部是"同时具备"。资产条目默认隐藏——
    /// 不是"资产"筛选没打开就永远不会出现在任何列表里,是"个人资产"这类
    /// 私密条目不该跟日常收藏混在一起刷屏,筛选里显式选中才看得到。
    private var filtered: [MemoryItem] {
        items.filter { item in
            (showAssets ? item.isAsset : !item.isAsset)
                && (selectedKinds.isEmpty || selectedKinds.contains(item.kind))
                && selectedTags.allSatisfy { item.tags.contains($0) }
                && item.matches(query)
        }
    }

    private var assetOverview: AssetOverview? {
        guard showAssets else { return nil }
        return AssetOverview(items: filtered)
    }

    var body: some View {
        NavigationStack {
            List {
                if let overview = assetOverview, !filtered.isEmpty {
                    AssetOverviewCard(overview: overview)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有收藏", systemImage: "sparkles.rectangle.stack")
                    } description: {
                        Text("粘贴文字或链接、导入文件,AI 会整理成记忆条目。")
                    } actions: {
                        Button("输入文字收藏") { showCompose = true }
                            .glassProminentButton()
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        showAssets ? "还没有资产记录" : "没有匹配的收藏",
                        systemImage: showAssets ? "creditcard" : "magnifyingglass",
                        description: Text(showAssets ? "点右上角「+」记一笔资产。" : "换个关键词,或取消选中的筛选。"))
                } else {
                    ForEach(filtered) { item in
                        NavigationLink {
                            MemoryDetailView(item: item)
                        } label: {
                            MemoryRow(item: item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                let attachment = MemoryPipeline.makeAttachment(from: item)
                                onConvertToTodo(attachment.title, attachment)
                            } label: {
                                Label("转为待办", systemImage: "checklist")
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("记忆")
            .onAppear {
                #if DEBUG
                // 截图验证用:直接弹出筛选浮层(popover 挂在工具栏按钮上,
                // appear 当帧触发有时不生效,延后一点再弹)
                if ProcessInfo.processInfo.arguments.contains("--demo-memory-filters") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showFilters = true
                    }
                }
                #endif
            }
            .searchable(text: $query, prompt: "搜索收藏")
            .searchSuggestions {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 输入内容命中标签名时,提供"按标签筛选"的快捷入口
                    ForEach(allTags.filter { $0.localizedStandardContains(query) },
                            id: \.self) { tag in
                        Button {
                            selectedTags.insert(tag)
                            query = ""
                        } label: {
                            Label("标签:\(tag)", systemImage: "tag")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("粘贴收藏", systemImage: "doc.on.clipboard") {
                            pasteFromClipboard()
                        }
                        Button("选择文件", systemImage: "folder") {
                            showFileImporter = true
                        }
                        Button("输入文字", systemImage: "square.and.pencil") {
                            showCompose = true
                        }
                        Divider()
                        Button("记一笔资产", systemImage: "creditcard") {
                            showAssetCompose = true
                        }
                        Divider()
                        Button("管理标签", systemImage: "tag") {
                            showTagManage = true
                        }
                    } label: {
                        Label("收藏", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilters = true
                    } label: {
                        Label("筛选", systemImage: activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .popover(isPresented: $showFilters) {
                        filterContent
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                MemoryComposeView()
            }
            .sheet(isPresented: $showAssetCompose) {
                AssetComposeView(onSaved: { showAssets = true })
            }
            .sheet(isPresented: $showTagManage) {
                MemoryTagManageView()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .plainText, .presentation, .data],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                MemoryPipeline.saveFile(url, context: context)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            .confirmationDialog(
                "删除这条收藏?原始文件会一并删除。", isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
                ), titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let item = pendingDelete {
                        Haptics.impact()
                        MemoryPipeline.delete(item, context: context)
                    }
                    pendingDelete = nil
                }
            }
        }
    }

    // MARK: - 筛选浮层

    /// 工具栏"筛选"按钮弹出的浮层:两行独立的 chips——第一行按来源格式筛,
    /// 第二行按内容标签筛,点选即筛(可多选,再点取消)。
    @ViewBuilder
    private var filterContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("筛选").font(.headline)
            Toggle(isOn: $showAssets) {
                Label("资产", systemImage: "creditcard")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.accentColor)
            .font(.footnote)
            if availableKinds.count > 1 {
                HorizontalChipRow {
                    ForEach(availableKinds, id: \.self) { kind in
                        Toggle(isOn: Binding(
                            get: { selectedKinds.contains(kind) },
                            set: { on in
                                if on { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
                            }
                        )) {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.footnote)
                    }
                }
            }
            if !allTags.isEmpty {
                HorizontalChipRow {
                    ForEach(allTags, id: \.self) { tag in
                        Toggle("#\(tag)", isOn: Binding(
                            get: { selectedTags.contains(tag) },
                            set: { on in
                                if on { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
                            }
                        ))
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.footnote)
                    }
                }
            }
            if activeFilterCount > 0 {
                Button("清除筛选", role: .destructive) {
                    selectedKinds.removeAll()
                    selectedTags.removeAll()
                    showAssets = false
                }
                .font(.footnote)
            }
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - 粘贴收藏(优先级:图片 > 链接 > 文字)

    #if os(iOS)
    private func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image, let data = image.pngData() {
            MemoryPipeline.saveImageData(data, context: context)
        } else if let url = pasteboard.url {
            MemoryPipeline.saveURL(url, context: context)
        } else if let text = pasteboard.string {
            MemoryPipeline.saveText(text, context: context)
        }
    }
    #else
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?
               .representation(using: .png, properties: [:]) {
            MemoryPipeline.saveImageData(data, context: context)
        } else if let url = NSURL(from: pasteboard) as URL? {
            // Finder 里拷贝的文件是 file URL,按文件收藏;网页地址按链接收藏
            if url.isFileURL {
                MemoryPipeline.saveFile(url, context: context)
            } else {
                MemoryPipeline.saveURL(url, context: context)
            }
        } else if let text = pasteboard.string(forType: .string) {
            MemoryPipeline.saveText(text, context: context)
        }
    }
    #endif
}

/// 列表卡片:类型图标 + 标题 + 摘要两行 + 标签/日期,整理中转菊花、失败给重试。
private struct MemoryRow: View {
    @Environment(\.modelContext) private var context
    let item: MemoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title.isEmpty ? (item.originalFileName ?? "正在整理…") : item.title)
                        .lineLimit(1)
                    if let assetValue = item.assetValue {
                        Spacer(minLength: 8)
                        Text(AssetFormat.currency(assetValue))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if item.status == .failed {
                        Button("整理失败,重试") {
                            MemoryPipeline.retry(item, context: context)
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    } else if !item.tags.isEmpty {
                        Text(item.tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                            .font(.footnote)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(TaskItem.format(item.createdAt))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            if item.status == .processing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 资产总览

/// 当前筛选出的资产条目的汇总:总额(有金额的条目求和)+ 条数 + 按分类
/// (assetTagName 之外的其他标签)拆出的小计,分类小计只是"参考"——一条
/// 资产可能有多个标签,金额会重复计进它命中的每个分类小计里。
private struct AssetOverview {
    let totalValue: Double
    let valuedCount: Int
    let totalCount: Int
    let byCategory: [(name: String, value: Double)]

    init(items: [MemoryItem]) {
        totalCount = items.count
        let valued = items.compactMap { $0.assetValue }
        totalValue = valued.reduce(0, +)
        valuedCount = valued.count

        var categoryTotals: [String: Double] = [:]
        for item in items {
            guard let value = item.assetValue else { continue }
            for tag in item.tags where tag != MemoryItem.assetTagName {
                categoryTotals[tag, default: 0] += value
            }
        }
        byCategory = categoryTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, value: $0.value) }
    }
}

private struct AssetOverviewCard: View {
    let overview: AssetOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("资产总览").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(overview.totalCount) 项")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Text(AssetFormat.currency(overview.totalValue))
                .font(.title2.bold().monospacedDigit())
            if overview.valuedCount < overview.totalCount {
                Text("其中 \(overview.totalCount - overview.valuedCount) 项未填金额,不计入总额")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !overview.byCategory.isEmpty {
                HorizontalChipRow {
                    ForEach(overview.byCategory, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.caption2).foregroundStyle(.secondary)
                            Text(AssetFormat.currency(entry.value))
                                .font(.footnote.monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// 资产金额的展示格式,列表卡片/总览卡共用。
enum AssetFormat {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "CNY"
        f.currencySymbol = "¥"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f
    }()

    static func currency(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "¥\(value)"
    }
}
