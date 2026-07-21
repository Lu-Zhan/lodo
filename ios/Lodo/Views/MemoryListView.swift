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
    @State private var filtersExpanded = false
    @State private var showCompose = false
    @State private var showFileImporter = false
    @State private var showTagManage = false

    private var allTags: [String] {
        MemoryTags.all(in: context)
    }

    /// 出现过的来源格式,按固定顺序(与内容标签是两套独立的筛选)。
    private var availableKinds: [MemoryKind] {
        let present = Set(items.map(\.kind))
        return [MemoryKind.text, .link, .pdf, .image, .file].filter(present.contains)
    }

    private var activeFilterCount: Int {
        selectedTags.count + selectedKinds.count
    }

    /// 文字过滤、格式筛选、标签筛选取交集;格式内部是"任一命中"
    /// (一条只有一种格式),标签内部是"同时具备"。
    private var filtered: [MemoryItem] {
        items.filter { item in
            (selectedKinds.isEmpty || selectedKinds.contains(item.kind))
                && selectedTags.allSatisfy { item.tags.contains($0) }
                && item.matches(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                tagFilterRow
                if items.isEmpty {
                    ContentUnavailableView(
                        "还没有收藏",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("粘贴文字或链接、导入文件,AI 会整理成记忆条目。"))
                } else if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的收藏", systemImage: "magnifyingglass",
                                           description: Text("换个关键词,或取消选中的筛选。"))
                } else {
                    ForEach(filtered) { item in
                        NavigationLink {
                            MemoryDetailView(item: item)
                        } label: {
                            MemoryRow(item: item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptics.impact()
                                MemoryPipeline.delete(item, context: context)
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
                // 截图验证用:直接展开筛选区
                if ProcessInfo.processInfo.arguments.contains("--demo-memory-filters") {
                    filtersExpanded = true
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
                            filtersExpanded = true
                            query = ""
                        } label: {
                            Label("标签:\(tag)", systemImage: "tag")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
                        Button("管理标签", systemImage: "tag") {
                            showTagManage = true
                        }
                    } label: {
                        Label("收藏", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                MemoryComposeView()
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
        }
    }

    // MARK: - 标签筛选行

    /// 搜索框下的筛选区,默认折叠;展开后两行独立的 chips:
    /// 第一行按来源格式筛,第二行按内容标签筛,点选即筛(可多选,再点取消)。
    @ViewBuilder
    private var tagFilterRow: some View {
        if !allTags.isEmpty || !availableKinds.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $filtersExpanded) {
                    if availableKinds.count > 1 {
                        HorizontalChipRow {
                            ForEach(availableKinds, id: \.self) { kind in
                                let selected = selectedKinds.contains(kind)
                                Button {
                                    if selected {
                                        selectedKinds.remove(kind)
                                    } else {
                                        selectedKinds.insert(kind)
                                    }
                                } label: {
                                    Label(kind.label, systemImage: kind.symbol)
                                }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(selected ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                    if !allTags.isEmpty {
                        HorizontalChipRow {
                            ForEach(allTags, id: \.self) { tag in
                                let selected = selectedTags.contains(tag)
                                Button("#\(tag)") {
                                    if selected {
                                        selectedTags.remove(tag)
                                    } else {
                                        selectedTags.insert(tag)
                                    }
                                }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(selected ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        if activeFilterCount > 0 {
                            // 折叠时也能看出有筛选生效
                            Text("\(activeFilterCount) 个选中")
                                .font(.footnote)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
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
                Text(item.title.isEmpty ? (item.originalFileName ?? "正在整理…") : item.title)
                    .lineLimit(1)
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
