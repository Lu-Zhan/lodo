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
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var assetDisplayCurrency = "CNY"
    @State private var showAssets = false
    @State private var showContacts = false
    @State private var showFilters = false
    @State private var showCompose = false
    @State private var showAssetCompose = false
    @State private var showContactCompose = false
    @State private var showContactGraph = false
    @State private var showFileImporter = false
    @State private var showTagManage = false
    @State private var pendingDelete: MemoryItem?
    #if os(iOS)
    @State private var showContactImportConfirm = false
    @State private var showContactPicker = false
    @State private var showContactExportPicker = false
    @State private var contactsPermissionDenied = false
    @State private var contactImportResultMessage: String?
    #endif
    #if DEBUG
    /// 截图验证用:simctl 点不了 List 行,--demo-contact-detail 直接弹详情。
    @State private var demoContactDetailTarget: MemoryItem?
    #endif

    /// 普通内容标签(不含"资产""人脉"这两个保留标签——它们各有自己独立的
    /// 筛选开关,不跟其他标签混在一起,更醒目也避免用户把它们当成普通标签删掉)。
    private var allTags: [String] {
        MemoryTags.all(in: context)
            .filter { $0 != MemoryItem.assetTagName && $0 != MemoryItem.contactTagName }
    }

    /// 出现过的来源格式,按固定顺序(与内容标签是两套独立的筛选)。
    private var availableKinds: [MemoryKind] {
        let present = Set(items.map(\.kind))
        return [MemoryKind.text, .link, .pdf, .image, .file].filter(present.contains)
    }

    private var activeFilterCount: Int {
        selectedTags.count + selectedKinds.count + (showAssets ? 1 : 0) + (showContacts ? 1 : 0)
    }

    /// 文字过滤、格式筛选、标签筛选取交集;格式内部是"任一命中"
    /// (一条只有一种格式),标签内部是"同时具备"。资产/人脉条目默认隐藏——
    /// 不是各自的筛选没打开就永远不会出现在任何列表里,是这类私密/结构化条目
    /// 不该跟日常收藏混在一起刷屏,筛选里显式选中才看得到。两个维度互相独立
    /// (不会出现"资产"打开时人脉也跟着冒出来)。
    private var filtered: [MemoryItem] {
        items.filter { item in
            (item.isAsset ? showAssets : true)
                && (item.isContact ? showContacts : true)
                && (selectedKinds.isEmpty || selectedKinds.contains(item.kind))
                && selectedTags.allSatisfy { item.tags.contains($0) }
                && item.matches(query)
        }
    }

    private var assetOverview: AssetOverview? {
        guard showAssets else { return nil }
        return AssetOverview(
            items: filtered, displayCurrency: assetDisplayCurrency,
            rates: ExchangeRateStore.shared)
    }

    var body: some View {
        NavigationStack {
            List {
                if let overview = assetOverview, !filtered.isEmpty {
                    // 单独一个 Section,和下面的条目列表分开——不然共用同一个隐式
                    // 分组时,条目那块顶部拿不到系统给的圆角(两块会贴在一起、
                    // 顶部变成直角)。不再自己画背景/边距,让系统给的行样式和
                    // 下面的条目卡片一样(同一套边距/圆角,大小才能对得上)。
                    Section {
                        AssetOverviewCard(overview: overview)
                    }
                }
                Section {
                    if items.isEmpty {
                        ContentUnavailableView {
                            Label("还没有收藏", systemImage: "sparkles.rectangle.stack")
                        } description: {
                            Text("粘贴文字或链接、导入文件,AI 会整理成记忆条目。")
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView(
                            showAssets ? "还没有资产记录" : "没有匹配的收藏",
                            systemImage: showAssets ? "creditcard" : "magnifyingglass",
                            description: Text(showAssets ? "点右上角「+」记一笔资产。" : "换个关键词,或取消选中的筛选。"))
                    } else {
                        ForEach(filtered) { item in
                            NavigationLink {
                                if item.isContact {
                                    ContactDetailView(item: item)
                                } else {
                                    MemoryDetailView(item: item)
                                }
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
                if ProcessInfo.processInfo.arguments.contains("--demo-seed-memory"), items.isEmpty {
                    seedDemoMemory()
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-assets-view") {
                    showAssets = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-contacts-view") {
                    showContacts = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-contact-compose") {
                    showContactCompose = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-contact-graph") {
                    showContacts = true
                    showContactGraph = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-contact-detail"),
                   let first = items.first(where: { $0.isContact }) {
                    demoContactDetailTarget = first
                }
                #if os(iOS)
                // 截图验证用:批量导出选择页不需要通讯录权限就能看列表(权限只在
                // 真正点"导出"时才用到),跳过 beginContactExport() 的权限请求直接弹出。
                if ProcessInfo.processInfo.arguments.contains("--demo-contact-export-picker") {
                    showContacts = true
                    showContactExportPicker = true
                }
                #endif
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
                if showContacts {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showContactGraph = true
                        } label: {
                            Label("关系图谱", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .navigation) {
                        Button {
                            Task { await beginContactExport() }
                        } label: {
                            Label("批量导出到通讯录", systemImage: "square.and.arrow.up")
                        }
                    }
                    #endif
                }
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
                        Button("记一位人脉", systemImage: "person.crop.circle.badge.plus") {
                            showContactCompose = true
                        }
                        #if os(iOS)
                        Button("从通讯录批量导入", systemImage: "person.crop.circle.badge.plus") {
                            showContactImportConfirm = true
                        }
                        Button("从通讯录选择导入", systemImage: "person.crop.circle.badge.checkmark") {
                            // CNContactPickerViewController 不需要先申请通讯录权限——
                            // 系统会把选人这一步隔离到独立进程,选完只把用户选中的那
                            // 几条给回 app,不算读取整个通讯录,直接弹选择器即可。
                            showContactPicker = true
                        }
                        #endif
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
            .sheet(isPresented: $showContactCompose) {
                ContactComposeView(onSaved: { showContacts = true })
            }
            .sheet(isPresented: $showContactGraph) {
                NavigationStack {
                    ContactGraphView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showContactGraph = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showTagManage) {
                MemoryTagManageView()
            }
            #if os(iOS)
            .sheet(isPresented: $showContactPicker) {
                ContactPickerView(
                    onPicked: { cnContacts in
                        showContactPicker = false
                        let result = ContactsBridge.importContacts(cnContacts, context: context)
                        contactImportResultMessage = importSummary(result)
                        showContacts = true
                    },
                    onCancel: { showContactPicker = false })
            }
            .sheet(isPresented: $showContactExportPicker) {
                ContactExportPickerView()
            }
            .confirmationDialog(
                "确定要导入通讯录中的全部联系人吗?", isPresented: $showContactImportConfirm,
                titleVisibility: .visible
            ) {
                Button("导入") { Task { await beginBulkImport() } }
            } message: {
                Text("已存在的人脉(按手机号/邮箱匹配)会自动跳过,不会重复导入。")
            }
            .alert("导入完成", isPresented: Binding(
                get: { contactImportResultMessage != nil },
                set: { if !$0 { contactImportResultMessage = nil } }
            )) {
                Button("好") { contactImportResultMessage = nil }
            } message: {
                Text(contactImportResultMessage ?? "")
            }
            .alert("无法访问通讯录", isPresented: $contactsPermissionDenied) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请在系统设置 → 隐私与安全性 → 通讯录 里允许 lodo 访问。")
            }
            #endif
            #if DEBUG
            .sheet(item: $demoContactDetailTarget) { target in
                NavigationStack { ContactDetailView(item: target) }
            }
            #endif
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
            HStack(spacing: 8) {
                Toggle(isOn: $showAssets) {
                    Label("资产", systemImage: "creditcard")
                }
                Toggle(isOn: $showContacts) {
                    Label("人脉", systemImage: "person.crop.circle")
                }
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
                    showContacts = false
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

    #if os(iOS)
    // MARK: - 通讯录批量导入/导出(权限门控,选择导入的系统选择器不需要走这里)

    private func beginBulkImport() async {
        guard await ContactsBridge.requestAccess() == .granted else {
            contactsPermissionDenied = true
            return
        }
        let result = ContactsBridge.importContacts(ContactsBridge.fetchAllContacts(), context: context)
        contactImportResultMessage = importSummary(result)
        showContacts = true
    }

    private func beginContactExport() async {
        guard await ContactsBridge.requestAccess() == .granted else {
            contactsPermissionDenied = true
            return
        }
        showContactExportPicker = true
    }

    private func importSummary(_ result: (imported: Int, skipped: Int)) -> String {
        var message = "已导入 \(result.imported) 位"
        if result.skipped > 0 { message += ",跳过 \(result.skipped) 位重复" }
        return message
    }
    #endif

    #if DEBUG
    // MARK: - 测试数据(--demo-seed-memory,仅在收藏为空时插入)

    /// 截图/测试用:文字、链接、资产几种典型场景,status 直接给 ready,
    /// 不经过 AI 整理请求。
    private func seedDemoMemory() {
        context.insert(MemoryItem(
            kind: .text, title: "读书笔记:原子习惯",
            summary: "习惯养成的四条定律:让提示显而易见、让渴望有吸引力、让行动简便易行、让奖励令人满意。",
            tags: ["读书"],
            sourceText: "《原子习惯》核心观点:微小的改变经过时间复利会带来巨大成果,关键在于打造让好习惯"
                + "显而易见、有吸引力、简便易行、令人满意的系统。",
            status: .ready))

        context.insert(MemoryItem(
            kind: .link, title: "如何做好周计划",
            summary: "一篇关于每周复盘与计划方法的文章,建议按角色划分任务优先级。",
            tags: ["效率", "文章"],
            sourceText: "文章提到每周日晚上花 20 分钟复盘上周、规划下周,按工作/生活/成长三个角色"
                + "分别列出本周重点。",
            urlString: "https://example.com/weekly-planning",
            status: .ready))

        context.insert(MemoryItem(
            kind: .link, title: "番茄炒蛋菜谱",
            summary: "经典家常菜做法,番茄先炒出汁再放鸡蛋。",
            tags: ["菜谱"],
            sourceText: "食材:番茄 2 个、鸡蛋 3 个、葱花少许、盐糖适量。做法:鸡蛋打散炒熟盛出,"
                + "番茄炒出汁后倒回鸡蛋翻炒均匀。",
            urlString: "https://example.com/recipe/tomato-egg",
            status: .ready))

        context.insert(MemoryItem(
            kind: .text, title: "产品评审会记录",
            summary: "确定下个版本优先做提醒稍等间隔的自定义,UI 细节待设计定稿。",
            tags: ["工作", "会议"],
            sourceText: "参会人:产品、设计、研发。结论:优先支持稍等间隔自定义,其次是标签管理;"
                + "UI 细节下周三前定稿。",
            status: .ready))

        context.insert(MemoryItem(
            kind: .text, title: "本月信用卡账单",
            summary: "本月信用消费汇总。",
            tags: [MemoryItem.assetTagName],
            sourceText: "账单周期:本月 1 日至月底,合计支出 1280.5 元,含餐饮、交通、日用品。",
            status: .ready, assetValue: 1280.5))

        let zhang = MemoryItem(
            kind: .text, title: "张三", summary: "前同事,喜欢爬山。",
            tags: [MemoryItem.contactTagName], sourceText: "前同事,喜欢爬山。咖啡",
            status: .ready, contactNickname: "小张", contactPhone: "13800000000",
            contactPreferences: "咖啡")
        let li = MemoryItem(
            kind: .text, title: "李四", summary: "大学同学。",
            tags: [MemoryItem.contactTagName], sourceText: "大学同学。",
            status: .ready, contactEmail: "li4@example.com")
        context.insert(zhang)
        context.insert(li)
        context.insert(ContactRelationship(memoryUUIDA: zhang.uuid, memoryUUIDB: li.uuid, label: "同事"))

        try? context.save()
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
                        Text(AssetFormat.currency(assetValue, code: item.assetCurrencyOrDefault))
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

/// 当前筛选出的资产条目的汇总:总额 + 条数 + 按分类(assetTagName 之外的其他
/// 标签)拆出的小计,分类小计只是"参考"——一条资产可能有多个标签,金额会
/// 重复计进它命中的每个分类小计里。总额与分类小计都换算成 `displayCurrency`
/// 求和(条目原本各种币种混在一起,不换算直接相加没有意义);某条资产的
/// 币种没有汇率(离线、或币种不在 ExchangeRateClient 覆盖范围内)时,不计入
/// 换算后的总额,单独计数提示。
@MainActor
private struct AssetOverview {
    let totalValue: Double
    let displayCurrency: String
    let valuedCount: Int
    let unratedCount: Int
    let totalCount: Int
    let byCategory: [(name: String, value: Double)]

    init(items: [MemoryItem], displayCurrency: String, rates: ExchangeRateStore) {
        self.displayCurrency = displayCurrency
        totalCount = items.count
        var total = 0.0
        var valuedCount = 0
        var unratedCount = 0
        var categoryTotals: [String: Double] = [:]
        for item in items {
            guard let value = item.assetValue else { continue }
            valuedCount += 1
            guard let converted = rates.convert(
                value, from: item.assetCurrencyOrDefault, to: displayCurrency) else {
                unratedCount += 1
                continue
            }
            total += converted
            for tag in item.tags where tag != MemoryItem.assetTagName {
                categoryTotals[tag, default: 0] += converted
            }
        }
        totalValue = total
        self.valuedCount = valuedCount
        self.unratedCount = unratedCount
        byCategory = categoryTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, value: $0.value) }
    }
}

private struct AssetOverviewCard: View {
    let overview: AssetOverview
    private var rates: ExchangeRateStore { ExchangeRateStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("资产总览").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(overview.totalCount) 项")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Text(AssetFormat.currency(overview.totalValue, code: overview.displayCurrency))
                .font(.title2.bold().monospacedDigit())
            if overview.valuedCount < overview.totalCount {
                Text("其中 \(overview.totalCount - overview.valuedCount) 项未填金额,不计入总额")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if rates.isUnavailable {
                Text("汇率不可用(需联网获取一次),不同币种暂按原样未换算求和")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if overview.unratedCount > 0 {
                Text("其中 \(overview.unratedCount) 项币种暂无汇率,不计入总额")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !overview.byCategory.isEmpty {
                HorizontalChipRow {
                    ForEach(overview.byCategory, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.caption2).foregroundStyle(.secondary)
                            Text(AssetFormat.currency(entry.value, code: overview.displayCurrency))
                                .font(.footnote.monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .task { await rates.refreshIfNeeded() }
    }
}

/// 资产金额的展示格式,列表卡片/总览卡共用;每种币种各自缓存一个 formatter
/// (NumberFormatter 构造有一定开销,币种数量不多,缓存比每次现造划算)。
enum AssetFormat {
    @MainActor private static var formatters: [String: NumberFormatter] = [:]

    @MainActor
    private static func formatter(for code: String) -> NumberFormatter {
        if let cached = formatters[code] { return cached }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        formatters[code] = f
        return f
    }

    @MainActor
    static func currency(_ value: Double, code: String) -> String {
        formatter(for: code).string(from: NSNumber(value: value)) ?? "\(code) \(value)"
    }
}
