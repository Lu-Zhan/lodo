import SwiftUI
import SwiftData
import LodoCore

/// "记忆" tab:AI 整理后的收藏条目列表,筛选靠侧栏的标签/资产行。
/// 新建入口(粘贴收藏/选文件/输入文字/记一笔资产)已随右下角那颗「+」一起去掉,
/// 收藏改为说给底下那条「问问 AI」(`memorize`)或从别的 app 分享进来;
/// `MemoryComposeView`/`AssetComposeView` 原样留着(前者健康页还在用),
/// 要恢复入口时挂回工具栏即可。
///
/// **这一页自己没有搜索框**——底下常驻着「问问 AI」那条,找东西说一句就行,
/// 再摆一个只按标题关键词匹配的本地搜索框是同一件事的两个入口、还弱一档;
/// 自然语言检索走 AI 助手(AgentHostView+Routing.answerFromMemory)。
struct MemoryListView: View {
    /// 抽屉推开时要把整条工具栏撤掉(理由同 ☰,见 sidebarToolbarButton 的注释)。
    @Environment(\.sidebarChrome) private var sidebarChrome
    /// 左滑"转为待办"交接:切到待办页并弹出预填标题+内容附件的新建表单(见 AppShellView)。
    let onConvertToTodo: (String, TaskAttachment) -> Void
    /// 条目详情的 push 栈。由外壳持有:深链回记忆页时要能弹回根,外壳也要据此
    /// 知道现在在不在二级页(在的话屏幕左边缘归系统返回手势,抽屉的唤出带要让开)。
    @Binding var path: [MemoryItem]
    /// 非 nil 时按这个标签筛选(侧栏标签行交接),消费后置 nil。
    @Binding var tagFilter: String?

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var items: [MemoryItem]
    /// 只为让标签行随"用户创建标签"变化刷新;全集经 MemoryTags 汇总。
    @Query private var createdTags: [MemoryTag]

    @State private var selectedTags: Set<String> = []
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var assetDisplayCurrency = "CNY"
    @State private var showAssets = false
    @State private var showTagManage = false
    @State private var pendingDelete: MemoryItem?

    /// 普通内容标签(不含"资产""人脉"这两个保留标签——资产有自己独立的显示开关,
    /// 人脉整个独立成页,都不该跟普通标签混在一起,也避免用户把它们当成普通标签删掉)。
    private var allTags: [String] {
        MemoryTags.all(in: context)
            .filter { !MemoryItem.hiddenByDefaultTagNames.contains($0) }
    }

    private var activeFilterCount: Int {
        selectedTags.count + (showAssets ? 1 : 0)
    }

    /// 当前筛选的一句话描述,给列表顶部那行"清除筛选"用。
    private var filterSummary: String {
        if showAssets { return MemoryItem.assetTagName }
        return selectedTags.sorted().map { "#" + $0 }.joined(separator: " ")
    }

    private func clearFilters() {
        selectedTags = []
        showAssets = false
    }

    /// 文字过滤与标签筛选取交集,标签内部是"同时具备"。资产条目默认隐藏——
    /// 不是筛选没打开就永远不会出现在任何列表里,是这类私密/结构化条目不该跟
    /// 日常收藏混在一起刷屏,侧栏点「资产」才看得到。人脉条目在这里**一律不出现**
    /// ——它整个独立成了一页(ContactListView),留在记忆列表里只会一条内容
    /// 两个入口、两副样子。
    private var filtered: [MemoryItem] {
        items.filter { item in
            (item.isAsset ? showAssets : true)
                && !item.isContact
                && selectedTags.allSatisfy { item.tags.contains($0) }
        }
    }

    private var assetOverview: AssetOverview? {
        guard showAssets else { return nil }
        return AssetOverview(
            items: filtered, displayCurrency: assetDisplayCurrency,
            rates: ExchangeRateStore.shared)
    }

    /// 外部带一个标签进来时按它筛选:资产有自己独立的显示开关(它默认从列表隐藏),
    /// 其余标签走普通的标签筛选。每次都先清掉上一轮的筛选,不做叠加——那一下是
    /// "我要看这一类",不是"再加一个条件"。
    /// **当前没有调用方**:唯一的入口(侧栏标签行)已去掉,见 `AppSidebarView`
    /// 文件头;机制留着,要恢复入口时把 `tagFilter` 接回去即可。
    private func consumeTagFilter(_ tag: String?) {
        guard let tag else { return }
        tagFilter = nil
        clearFilters()
        switch tag {
        case MemoryItem.assetTagName: showAssets = true
        default: selectedTags = [tag]
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                if activeFilterCount > 0 {
                    // 筛选现在只从侧栏(标签/资产行)进来,工具栏那颗筛选按钮
                    // 已经撤掉——不给一个就地取消的入口的话,点进某个标签之后
                    // 就出不来了。
                    Section {
                        Button(role: .destructive) {
                            clearFilters()
                        } label: {
                            Label("清除筛选:\(filterSummary)", systemImage: "xmark.circle")
                                .font(.body)
                        }
                    }
                }
                Section {
                    // 空态的判据是"筛完之后什么都不剩 + 现在没开筛选",不是
                    // `items.isEmpty`:人脉条目也是 MemoryItem,库里只有人脉时
                    // items 不空、这一页却一条都没有,那时该说的是"还没有收藏",
                    // 不是"这个筛选下没有"(用户根本没开筛选)。
                    if filtered.isEmpty, activeFilterCount == 0 {
                        ContentUnavailableView {
                            Label("还没有收藏", systemImage: "sparkles.rectangle.stack")
                        } description: {
                            Text("在底下那条「问问 AI」里说一句要记的事,或从别的 app 分享到 lodo,AI 会整理成记忆条目。")
                        }
                    } else if filtered.isEmpty {
                        ContentUnavailableView(
                            showAssets ? "还没有资产记录" : "这个筛选下还没有收藏",
                            systemImage: showAssets ? "creditcard" : "line.3.horizontal.decrease",
                            description: Text(showAssets ? "在底下那条「问问 AI」里说一句要记的资产。" : "取消上面选中的筛选就能看到全部。"))
                    } else {
                        ForEach(filtered) { item in
                            // 目的地统一挂在下面的 navigationDestination 上:
                            // NavigationStack(path:) 要靠值驱动才能把 push 栈
                            // 暴露给外壳(见上面 path 的注释)。
                            NavigationLink(value: item) {
                                MemoryRow(item: item)
                            }
                            // 和 TaskRowView 同一档紧凑内边距(默认竖向 11)。
                            .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                            // 全部收在 trailing:向右拖归抽屉(见 TaskRowView 同款注释)。
                            // "转为待办"排在最靠外当 full swipe,删除挪到里面。
                            .swipeActions(edge: .trailing) {
                                Button {
                                    let attachment = MemoryPipeline.makeAttachment(from: item)
                                    onConvertToTodo(attachment.title, attachment)
                                } label: {
                                    Label("转为任务", systemImage: "checklist")
                                }
                                .tint(.accentColor)
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("记忆")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                // 首次挂载时侧栏可能已经把标签放进来了(外壳先切页面再设筛选)
                consumeTagFilter(tagFilter)
                #if DEBUG
                // 截图验证用:摆出"按标签筛选中"的状态,看列表顶部那行清除入口。
                if ProcessInfo.processInfo.arguments.contains("--demo-memory-filters") {
                    selectedTags = Set(allTags.prefix(1))
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-seed-memory"), items.isEmpty {
                    seedDemoMemory()
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-assets-view") {
                    showAssets = true
                }
                #endif
            }
            .onChange(of: tagFilter) { _, tag in consumeTagFilter(tag) }
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            // 页面自己的操作收在右上角。「管理标签」不是新建入口,所以它没跟着
            // 右下角那颗「+」一起去掉(收藏一律说给底下那条「问问 AI」)。
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false), path.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showTagManage = true
                        } label: {
                            Label("管理标签", systemImage: "tag")
                        }
                    }
                }
            }
            .sidebarToolbarButton()
            .askBar(focus: .memory, isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false))
            .sheet(isPresented: $showTagManage) {
                MemoryTagManageView()
            }
            .confirmationDialog(
                "删除这条收藏?原始文件会一并删除。", isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
                ), titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let item = pendingDelete {
                        Haptics.warning()
                        MemoryPipeline.delete(item, context: context)
                    }
                    pendingDelete = nil
                }
            }
        }
    }

    #if DEBUG
    // MARK: - 测试数据(--demo-seed-memory,仅在收藏为空时插入)

    /// 截图/测试用:文字、链接、资产几种典型场景,status 直接给 ready,
    /// 不经过 AI 整理请求。样板人脉归人脉页自己种(见 ContactListView)。
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

        context.insert(MemoryItem(
            kind: .text, title: "自住房产",
            summary: "首付 60 万,贷款 30 年。",
            tags: [MemoryItem.assetTagName, "房产"],
            sourceText: "市值约 300 万,房贷还剩 100 万,商业贷款利率 4.5%。",
            status: .ready, assetValue: 3000000, assetLiability: 1000000,
            assetInterestRate: 4.5))

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
            // AI 自动记录的条目(auto_memorize,打了 autoTagName)用 sparkles
            // 图标取代内容类型图标(反正这类条目恒为 .text,类型图标本来也没有
            // 信息量),和聊天里 memoryResultContent 的图标语言保持一致,让用户
            // 一眼能从列表里认出"这条是 AI 自己记的",不用点进详情看标签。
            // 强调色只给**有信息量**的那个:sparkles 表示"这条是 AI 自己记的",
            // 值得一眼认出;而内容类型图标每行都一样、又不可点,染成强调色只是
            // 让整列重复十几个彩色色块,把视线从标题上抢走(换成橙色主色后尤其
            // 明显)。类型图标退成中性,一行就只剩标签一处强调色。
            Image(systemName: item.isAutoRecorded ? "sparkles" : item.kind.symbol)
                .foregroundStyle(item.isAutoRecorded ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.secondary))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title.isEmpty ? (item.originalFileName ?? "正在整理…") : item.title)
                        .font(.body.weight(.medium))
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
                if item.assetLiability != nil || item.assetInterestRate != nil {
                    HStack(spacing: 6) {
                        if let liability = item.assetLiability {
                            Text("负债 " + AssetFormat.currency(liability, code: item.assetCurrencyOrDefault))
                        }
                        if let rate = item.assetInterestRate {
                            Text("利率 " + AssetFormat.percent(rate))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(LodoColor.critical)
                }
                HStack(spacing: 6) {
                    if item.status == .failed {
                        Button("整理失败,重试") {
                            MemoryPipeline.retry(item, context: context)
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .foregroundStyle(LodoColor.critical)
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
    }
}

// MARK: - 资产总览

/// 当前筛选出的资产条目的汇总:总额 + 条数 + 按分类(assetTagName 之外的其他
/// 标签)拆出的小计,分类小计只是"参考"——一条资产可能有多个标签,金额会
/// 重复计进它命中的每个分类小计里。总额与分类小计都换算成 `displayCurrency`
/// 求和(条目原本各种币种混在一起,不换算直接相加没有意义);某条资产的
/// 币种没有汇率(离线、或币种不在 ExchangeRateClient 覆盖范围内)时,不计入
/// 换算后的总额,单独计数提示。负债同样换算求和(与对应资产同币种),
/// 净资产 = 总资产 − 总负债,分类小计不含负债(只是资产的参考细分)。
@MainActor
private struct AssetOverview {
    let totalValue: Double
    let totalLiability: Double
    let netWorth: Double
    let displayCurrency: String
    let valuedCount: Int
    let unratedCount: Int
    let liabilityCount: Int
    let unratedLiabilityCount: Int
    let totalCount: Int
    let byCategory: [(name: String, value: Double)]

    init(items: [MemoryItem], displayCurrency: String, rates: ExchangeRateStore) {
        self.displayCurrency = displayCurrency
        // 只统计真正打了「资产」标签的条目——调用方按"资产"筛选开关传入的
        // items 实际上不保证已经过滤过(筛选谓词对非资产条目直接放行),这里
        // 内部再过滤一次兜底,避免总数/未填金额计数把普通收藏也算进去。
        let assetItems = items.filter(\.isAsset)
        totalCount = assetItems.count
        var total = 0.0
        var valuedCount = 0
        var unratedCount = 0
        var totalLiability = 0.0
        var liabilityCount = 0
        var unratedLiabilityCount = 0
        var categoryTotals: [String: Double] = [:]
        for item in assetItems {
            if let value = item.assetValue {
                valuedCount += 1
                if let converted = rates.convert(
                    value, from: item.assetCurrencyOrDefault, to: displayCurrency) {
                    total += converted
                    for tag in item.tags where tag != MemoryItem.assetTagName {
                        categoryTotals[tag, default: 0] += converted
                    }
                } else {
                    unratedCount += 1
                }
            }
            if let liabilityValue = item.assetLiability {
                liabilityCount += 1
                if let converted = rates.convert(
                    liabilityValue, from: item.assetCurrencyOrDefault, to: displayCurrency) {
                    totalLiability += converted
                } else {
                    unratedLiabilityCount += 1
                }
            }
        }
        totalValue = total
        self.totalLiability = totalLiability
        netWorth = total - totalLiability
        self.valuedCount = valuedCount
        self.unratedCount = unratedCount
        self.liabilityCount = liabilityCount
        self.unratedLiabilityCount = unratedLiabilityCount
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
                Text("资产总览").font(.body).foregroundStyle(.secondary)
                Spacer()
                Text("\(overview.totalCount) 项")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Text(AssetFormat.currency(overview.totalValue, code: overview.displayCurrency))
                .font(.title2.bold().monospacedDigit())
            if overview.valuedCount < overview.totalCount {
                Text("其中 \(overview.totalCount - overview.valuedCount) 项未填金额,不计入总额")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            if rates.isUnavailable {
                Text("汇率不可用(需联网获取一次),不同币种暂按原样未换算求和")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else if overview.unratedCount > 0 {
                Text("其中 \(overview.unratedCount) 项币种暂无汇率,不计入总额")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            if overview.liabilityCount > 0 {
                HStack {
                    Text("总负债").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text("-" + AssetFormat.currency(overview.totalLiability, code: overview.displayCurrency))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(LodoColor.critical)
                }
                HStack {
                    Text("净资产").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text(AssetFormat.currency(overview.netWorth, code: overview.displayCurrency))
                        .font(.body.bold().monospacedDigit())
                }
                if !rates.isUnavailable && overview.unratedLiabilityCount > 0 {
                    Text("其中 \(overview.unratedLiabilityCount) 项负债币种暂无汇率,不计入净资产")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            if !overview.byCategory.isEmpty {
                HorizontalChipRow {
                    ForEach(overview.byCategory, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.caption).foregroundStyle(.secondary)
                            Text(AssetFormat.currency(entry.value, code: overview.displayCurrency))
                                .font(.subheadline.monospacedDigit())
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

    /// 利率的展示格式,存的就是百分比数值本身(如 4.5 表示 4.5%),不是小数。
    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return f
    }()

    static func percent(_ value: Double) -> String {
        (percentFormatter.string(from: NSNumber(value: value)) ?? "\(value)") + "%"
    }
}
