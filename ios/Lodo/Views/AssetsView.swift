import SwiftUI
import SwiftData
import LodoCore

/// 资产:一份隔几个月更新一次的资产台账,**不记日常消费**。四组:
/// - 资产(房产/车辆/存款/投资/保险……):打了「资产」标签的记忆条目(同原来记忆页里
///   那套,AI 收藏、记忆搜索、问 AI 都能命中),带金额、负债(房贷车贷本金)、利率;
/// - 收入(月薪、奖金)与固定支出(房贷车贷月供、房租、保险):`FinanceEntry`,
///   按月折算出"每月结余";
/// - 信用卡:额度、银行、账单日、还款日,还款日前一天自动生成一条提醒任务
///   (`FinanceReminders`)。
///
/// 顶上一条「全部 | 收入 | 支出 | 统计」切换(`AssetTab`):全部 = 总览卡 + 所有条目;
/// 收入 = 收入各项;支出 = 月估计消费 + 固定支出 + 负债 + 信用卡;统计 = 总资产趋势与
/// 各项组成(`AssetStatsSections`)。资产可以设成不计入总资产(`MemoryItem.assetExcluded`),
/// 不进净资产、趋势、组成。
///
/// 总览卡:净资产 + 每月收支;有哪一项超过 3 个月没更新就挂一行提示。
/// 新建收在右上角「+」——收入/支出/信用卡 AI 接不了(同人脉页右上角那两颗的道理)。
/// 「+」旁边是共享:整本台账经 iCloud 共享给家人一起记(`SharedTripSync.prepareAssetShare`,
/// 同旅行共享那套),对方加入之前自己记的那些不会被传过去。
struct AssetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.lodoAccent) private var lodoAccent
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var displayCurrency = "CNY"

    @Query private var memoryItems: [MemoryItem]
    @Query(sort: \FinanceEntry.sortIndex) private var entries: [FinanceEntry]

    @State private var editingAsset: AssetSheet?
    @State private var editingEntry: FinanceSheet?
    @State private var pendingDeleteAsset: MemoryItem?
    @State private var now = Date()
    @State private var tab: AssetTab = .all
    @State private var showingShare = false
    @State private var shareError: String?
    @Environment(\.sectionIsActive) private var isActive

    private var sync: SharedTripSync { SharedTripSync.shared }
    private var assetShare: SharedTripSync.AssetShareState? { sync.assetShare }

    private var rates: ExchangeRateStore { ExchangeRateStore.shared }

    private var assets: [MemoryItem] {
        memoryItems.filter(\.isAsset).sorted { $0.createdAt < $1.createdAt }
    }

    /// 计入总资产的那些(净资产、趋势、组成只算它们)。
    private var countedAssets: [MemoryItem] {
        assets.filter { !$0.assetExcluded }
    }

    private func entries(_ kind: FinanceKind) -> [FinanceEntry] {
        entries.filter { $0.kind == kind && !$0.estimated }
    }

    /// 月估计消费(支出里的 `estimated`)。
    private var spendingEntries: [FinanceEntry] {
        entries.filter { $0.kind == .expense && $0.estimated }
    }

    /// 有负债的资产(支出页「负债」那一组)。
    private var liabilityAssets: [MemoryItem] {
        assets.filter { ($0.assetLiability ?? 0) > 0 }
    }

    private var isEmpty: Bool { assets.isEmpty && entries.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if isEmpty {
                    emptyState
                } else {
                    tabBar
                    switch tab {
                    case .all:
                        Section { overviewCard }
                        assetSections
                        financeSection(.income)
                        spendingSection
                        financeSection(.expense)
                        financeSection(.creditCard)
                    case .income:
                        incomeTab
                    case .expense:
                        expenseTab
                    case .stats:
                        statsTab
                    }
                }
            }
            .pageTitle("资产")
            // 标题在顶部正中(同记忆页),不用大标题——下面紧跟着切换条。
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false) {
                    ToolbarItem(placement: .primaryAction) { shareButton }
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
            }
            .sidebarToolbarButton()
            .askBar(focus: .assets)
            .sheet(item: $editingAsset) { sheet in
                AssetEditView(existing: sheet.item, presetCategory: sheet.category)
                    .tint(lodoAccent.accent)
                    .environment(\.lodoAccent, lodoAccent)
            }
            .sheet(item: $editingEntry) { sheet in
                FinanceEntryEditView(kind: sheet.kind, existing: sheet.entry, estimated: sheet.estimated)
                    .tint(lodoAccent.accent)
                    .environment(\.lodoAccent, lodoAccent)
            }
            .confirmationDialog("删除这项资产?", isPresented: Binding(
                get: { pendingDeleteAsset != nil }, set: { if !$0 { pendingDeleteAsset = nil } }),
                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let item = pendingDeleteAsset { MemoryPipeline.delete(item, context: context) }
                    pendingDeleteAsset = nil
                }
            } message: {
                if isShared(pendingDeleteAsset?.assetLedgerUUID) {
                    Text("这项在共享台账里,删除后共享的成员那边也会一起删掉。")
                }
            }
            .sheet(isPresented: $showingShare) {
                AssetShareSheet(assets: assets, entries: entries)
                    .tint(lodoAccent.accent)
                    .environment(\.lodoAccent, lodoAccent)
            }
            .alert("共享没有成功", isPresented: Binding(
                get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(shareError ?? "")
            }
            // 共享同步里的失败(系统共享界面、推送)经 SharedTripSync.lastError 报上来;
            // 只在这一页显示着时接走,旅行详情页开着时归它。
            .onChange(of: sync.lastError) { _, message in
                guard isActive, let message else { return }
                sync.lastError = nil
                shareError = message
            }
            .task {
                await rates.refreshIfNeeded()
                FinanceReminders.sync(context: context)
            }
            .onAppear { now = Date() }
            #if DEBUG
            .onAppear(perform: applyDemoArguments)
            #endif
        }
    }

    // MARK: - 共享

    private func isShared(_ ledgerUUID: UUID?) -> Bool {
        guard let ledgerUUID else { return false }
        return assetShare?.ledgerUUID == ledgerUUID
    }

    /// 点开共享确认页(`AssetShareSheet`):开关、当前状态、逐条勾选,确认后才生效。
    private var shareButton: some View {
        Button {
            showingShare = true
        } label: {
            Label(assetShare == nil ? "共享资产" : "共享成员",
                  systemImage: assetShare == nil ? "person.crop.circle.badge.plus" : "person.2.fill")
        }
        .disabled(isEmpty && assetShare == nil)
    }

    /// 总览卡顶上那一行:共享状态(共享了几项、是否在同步),点它也能打开确认页。
    @ViewBuilder
    private var shareStatus: some View {
        if let assetShare {
            let pending = sync.pendingCounts[assetShare.ledgerUUID] ?? 0
            let count = assets.filter { $0.assetLedgerUUID == assetShare.ledgerUUID }.count
                + entries.filter { $0.ledgerUUID == assetShare.ledgerUUID }.count
            Label {
                if pending > 0 {
                    Text("正在同步 \(pending) 项")
                } else if assetShare.role == .owner {
                    Text("已共享 \(count) 项")
                } else {
                    Text("加入的共享台账 · \(count) 项")
                }
            } icon: {
                Image(systemName: "person.2.fill")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(lodoAccent.accent)
        }
    }

    // MARK: - 新建

    private var addMenu: some View {
        Menu {
            addMenuItems
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    /// 空态中间那颗「添加」。**不能直接拿 `addMenu` 套 `.buttonStyle(.borderedProminent)`**:
    /// Menu 套按钮样式时标签会被吃掉,只剩一块没字的强调色椭圆。这里自己画标签,
    /// 填充上的文字用 `onFill`(暗色下是近黑,见 LodoPalette)。
    private var emptyAddMenu: some View {
        Menu {
            addMenuItems
        } label: {
            // 不用 Label:ContentUnavailableView 的 actions 里 Menu 的标签按纯图标显示,
            // 文字会被吞掉。
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("添加")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(lodoAccent.onFill)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(lodoAccent.fill))
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Section("资产") {
            ForEach(AssetCategory.presets, id: \.self) { category in
                Button {
                    editingAsset = AssetSheet(item: nil, category: category)
                } label: {
                    Label(LocalizedStringKey(category), systemImage: AssetCategory.symbol(for: category))
                }
            }
        }
        Section {
            Button {
                editingEntry = FinanceSheet(kind: .income, entry: nil)
            } label: { Label("收入", systemImage: "arrow.down.circle") }
            Button {
                editingEntry = FinanceSheet(kind: .expense, entry: nil)
            } label: { Label("固定支出", systemImage: "arrow.up.circle") }
            Button {
                editingEntry = FinanceSheet(kind: .expense, entry: nil, estimated: true)
            } label: { Label("月估计消费", systemImage: "cart") }
            Button {
                editingEntry = FinanceSheet(kind: .creditCard, entry: nil)
            } label: { Label("信用卡", systemImage: "creditcard") }
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("还没有记过资产", systemImage: "banknote")
            } description: {
                Text("记下房子、车子、存款,每月的收入和固定支出,还有信用卡。不用记日常花销,隔几个月回来更新一次就好。")
            } actions: {
                emptyAddMenu
            }
            .emptyStateFill()
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 总览

    private var netWorth: FinancePlan.NetWorth {
        FinancePlan.netWorth(
            countedAssets.map { (value: $0.assetValue, liability: $0.assetLiability,
                                 currency: $0.assetCurrencyOrDefault) },
            in: displayCurrency) { rates.convert($0, from: $1, to: $2) }
    }

    private var monthly: FinancePlan.MonthlyTotal {
        FinancePlan.monthlyTotal(entries.map(\.snapshot), in: displayCurrency, now: now) {
            rates.convert($0, from: $1, to: $2)
        }
    }

    /// 超过 `FinancePlan.staleMonths` 个月没更新的条数。
    private var staleCount: Int {
        let dates = assets.map(\.assetUpdatedAtOrCreated)
            + entries.filter { !$0.estimated }.map(\.updatedAt)
        return dates.filter { FinancePlan.monthsSince($0, now: now) >= FinancePlan.staleMonths }.count
    }

    private var overviewCard: some View {
        let worth = netWorth
        let month = monthly
        return VStack(alignment: .leading, spacing: 12) {
            shareStatus
            VStack(alignment: .leading, spacing: 2) {
                Text("净资产").font(.subheadline).foregroundStyle(.secondary)
                Text(AssetFormat.currency(worth.net, code: displayCurrency))
                    .font(.title.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 12) {
                    Text("资产 \(AssetFormat.currency(worth.assets, code: displayCurrency))")
                    Text("负债 \(AssetFormat.currency(worth.liabilities, code: displayCurrency))")
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            if !entries(.income).isEmpty || !entries(.expense).isEmpty || !spendingEntries.isEmpty {
                Divider()
                HStack(alignment: .top) {
                    monthlyFigure("每月收入", month.income, color: LodoColor.positive)
                    monthlyFigure("每月支出", month.expense + month.spending, color: LodoColor.critical)
                    monthlyFigure("每月结余", month.net, color: .primary)
                }
                if month.irregularCount > 0 {
                    Text("另有 \(month.irregularCount) 项不定期的没有折算进每月。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            let missing = Array(Set(worth.missingCurrencies + month.missingCurrencies)).sorted()
            if !missing.isEmpty {
                // 换不出汇率的不能默默当 0 吞掉,如实说清楚少算了哪几种。
                Text("以下币种暂时换不到汇率,没有计入:\(missing.joined(separator: "、"))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if worth.unvaluedCount > 0 {
                Text("有 \(worth.unvaluedCount) 项资产没填金额,不计入总额。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if excludedCount > 0 {
                Text("有 \(excludedCount) 项资产设成了不计入总资产。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if staleCount > 0 {
                Label("有 \(staleCount) 项超过 \(FinancePlan.staleMonths) 个月没更新了,点进去核对一下金额。",
                      systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(lodoAccent.accent)
            }
        }
        .padding(.vertical, 4)
    }

    private func monthlyFigure(_ title: LocalizedStringKey, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(AssetFormat.currency(value, code: displayCurrency))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 资产

    private func category(of item: MemoryItem) -> String {
        AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames)
    }

    @ViewBuilder
    private var assetSections: some View {
        let groups = AssetCategory.orderedGroups(assets.map(category(of:)))
        ForEach(groups, id: \.self) { group in
            Section {
                ForEach(assets.filter { category(of: $0) == group }) { item in
                    assetRow(item)
                }
            } header: {
                Label(LocalizedStringKey(group), systemImage: AssetCategory.symbol(for: group))
            }
        }
    }

    private func assetRow(_ item: MemoryItem) -> some View {
        Button {
            editingAsset = AssetSheet(item: item, category: category(of: item))
        } label: {
            FinanceRow(symbol: AssetCategory.symbol(for: category(of: item)),
                       title: item.title,
                       detail: assetDetail(item),
                       amount: item.assetValue.map { AssetFormat.currency($0, code: item.assetCurrencyOrDefault) },
                       amountColor: .primary,
                       stale: FinancePlan.monthsSince(item.assetUpdatedAtOrCreated, now: now)
                           >= FinancePlan.staleMonths,
                       shared: marksShared(item.assetLedgerUUID))
        }
        .pressableCard()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeleteAsset = item
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 行上挂不挂「共享」小图标:条目是逐条勾选共享的,共享的和没共享的混在一起,
    /// 两种身份都要分开。
    private func marksShared(_ ledgerUUID: UUID?) -> Bool {
        isShared(ledgerUUID)
    }

    private func assetDetail(_ item: MemoryItem) -> String {
        var parts: [String] = []
        if let liability = item.assetLiability {
            parts.append(localized("负债 \(AssetFormat.currency(liability, code: item.assetCurrencyOrDefault))"))
        }
        if let rate = item.assetInterestRate {
            parts.append(localized("利率 \(AssetFormat.percent(rate))"))
        }
        if item.assetExcluded {
            parts.append(localized("不计入总资产"))
        }
        parts.append(updatedText(item.assetUpdatedAtOrCreated))
        if let name = item.sharedAddedBy, !name.isEmpty, isShared(item.assetLedgerUUID) {
            parts.append(localized("由 \(name) 添加"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 切换条与各档

    /// 「全部 | 收入 | 支出 | 统计」,同任务页顶部那条(`SlidingSwitch`)。
    private var tabBar: some View {
        Section {
            SlidingSwitch(options: AssetTab.allCases, selection: $tab, height: 44,
                          font: .body.weight(.semibold)) {
                Text($0.title)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var excludedCount: Int {
        assets.filter(\.assetExcluded).count
    }

    @ViewBuilder
    private var incomeTab: some View {
        let month = monthly
        Section {
            monthlySummaryRow([("每月收入", month.income, LodoColor.positive)])
        }
        if entries(.income).isEmpty {
            addHintSection("还没有记收入", systemImage: "arrow.down.circle") {
                editingEntry = FinanceSheet(kind: .income, entry: nil)
            }
        } else {
            financeSection(.income)
        }
    }

    @ViewBuilder
    private var expenseTab: some View {
        let month = monthly
        Section {
            monthlySummaryRow([
                ("月估计消费", month.spending, LodoColor.critical),
                ("固定支出", month.expense, LodoColor.critical),
                ("每月支出", month.expense + month.spending, .primary),
            ])
        }
        if spendingEntries.isEmpty {
            addHintSection("还没有估计每月消费", systemImage: "cart") {
                editingEntry = FinanceSheet(kind: .expense, entry: nil, estimated: true)
            }
        } else {
            spendingSection
        }
        financeSection(.expense)
        liabilitySection
        financeSection(.creditCard)
    }

    @ViewBuilder
    private var statsTab: some View {
        let month = monthly
        AssetStatsSections(
            trend: AssetTrend.build(assets: countedAssets.map(\.assetHistory), monthlyNet: month.net,
                                    in: displayCurrency, now: now) { rates.convert($0, from: $1, to: $2) },
            monthlyNet: month.net,
            assets: FinancePlan.composition(
                countedAssets.compactMap { item in
                    item.assetValue.map { (name: category(of: item), amount: $0,
                                           currency: item.assetCurrencyOrDefault) }
                },
                in: displayCurrency) { rates.convert($0, from: $1, to: $2) },
            liabilities: FinancePlan.composition(
                countedAssets.compactMap { item in
                    item.assetLiability.map { (name: item.title, amount: $0,
                                               currency: item.assetCurrencyOrDefault) }
                },
                in: displayCurrency) { rates.convert($0, from: $1, to: $2) },
            income: FinancePlan.composition(
                entries(.income).compactMap { entry in
                    FinancePlan.monthlyAmount(entry.snapshot).map {
                        (name: FinanceText.displayTitle(entry), amount: $0, currency: entry.currency)
                    }
                },
                in: displayCurrency) { rates.convert($0, from: $1, to: $2) },
            currency: displayCurrency,
            excludedCount: excludedCount,
            now: now)
    }

    /// 收入/支出两档顶上那一行每月合计。
    private func monthlySummaryRow(_ figures: [(LocalizedStringKey, Double, Color)]) -> some View {
        HStack(alignment: .top) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                monthlyFigure(figure.0, figure.1, color: figure.2)
            }
        }
        .padding(.vertical, 4)
    }

    /// 某一档还没有内容时的一行:说明 + 直接新建。
    private func addHintSection(_ title: LocalizedStringKey, systemImage: String,
                                action: @escaping () -> Void) -> some View {
        Section {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .pressableCard()
        }
    }

    /// 月估计消费:吃饭、日常开销这类估个大概的每月花销。
    @ViewBuilder
    private var spendingSection: some View {
        if !spendingEntries.isEmpty {
            Section {
                ForEach(spendingEntries) { entry in financeRow(entry) }
            } header: {
                Label("月估计消费", systemImage: "cart")
            } footer: {
                Text("估个大概就行,算进每月结余,也用来估计未来几个月的资产。")
            }
        }
    }

    /// 负债:有负债本金的资产(房贷车贷),点进去更新。
    @ViewBuilder
    private var liabilitySection: some View {
        if !liabilityAssets.isEmpty {
            Section {
                ForEach(liabilityAssets) { item in
                    Button {
                        editingAsset = AssetSheet(item: item, category: category(of: item))
                    } label: {
                        FinanceRow(symbol: AssetCategory.symbol(for: category(of: item)),
                                   title: item.title,
                                   detail: liabilityDetail(item),
                                   amount: item.assetLiability.map {
                                       AssetFormat.currency($0, code: item.assetCurrencyOrDefault)
                                   },
                                   amountColor: LodoColor.critical,
                                   stale: FinancePlan.monthsSince(item.assetUpdatedAtOrCreated, now: now)
                                       >= FinancePlan.staleMonths,
                                   shared: marksShared(item.assetLedgerUUID))
                    }
                    .pressableCard()
                }
            } header: {
                Label("负债", systemImage: "building.columns")
            } footer: {
                Text("负债记在对应的资产上(还欠多少本金),每月的月供记在「固定支出」里。")
            }
        }
    }

    private func liabilityDetail(_ item: MemoryItem) -> String {
        var parts: [String] = []
        if let rate = item.assetInterestRate {
            parts.append(localized("利率 \(AssetFormat.percent(rate))"))
        }
        parts.append(updatedText(item.assetUpdatedAtOrCreated))
        return parts.joined(separator: " · ")
    }

    // MARK: - 收入 / 支出 / 信用卡

    @ViewBuilder
    private func financeSection(_ kind: FinanceKind) -> some View {
        let list = entries(kind)
        if !list.isEmpty {
            Section {
                ForEach(list) { entry in financeRow(entry) }
            } header: {
                switch kind {
                case .income: Label("收入", systemImage: "arrow.down.circle")
                case .expense: Label("固定支出", systemImage: "arrow.up.circle")
                case .creditCard: Label("信用卡", systemImage: "creditcard")
                }
            } footer: {
                if kind == .creditCard {
                    Text("开了提醒的卡,会在还款日前一天自动生成一条还款任务。")
                }
            }
        }
    }

    private func financeRow(_ entry: FinanceEntry) -> some View {
        Button {
            editingEntry = FinanceSheet(kind: entry.kind, entry: entry, estimated: entry.estimated)
        } label: {
            FinanceRow(symbol: symbol(for: entry),
                       title: FinanceText.displayTitle(entry),
                       detail: financeDetail(entry),
                       amount: amountText(entry),
                       amountColor: entry.kind == .income ? LodoColor.positive
                           : entry.kind == .expense ? LodoColor.critical : .primary,
                       // 月估计消费是估个大概,不催着核对。
                       stale: !entry.estimated
                           && FinancePlan.monthsSince(entry.updatedAt, now: now) >= FinancePlan.staleMonths,
                       reminding: entry.kind == .creditCard && entry.remindEnabled && entry.dayOfMonth != nil,
                       shared: marksShared(entry.ledgerUUID))
        }
        .pressableCard()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                FinanceReminders.removeReminder(for: entry, context: context)
                context.delete(entry)
                try? context.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func symbol(for entry: FinanceEntry) -> String {
        switch entry.kind {
        case .income: return "arrow.down.circle.fill"
        case .expense: return entry.estimated ? "cart.fill" : "arrow.up.circle.fill"
        case .creditCard: return "creditcard.fill"
        }
    }

    private func amountText(_ entry: FinanceEntry) -> String? {
        guard let amount = entry.amount else { return nil }
        let money = AssetFormat.currency(amount, code: entry.currency)
        switch entry.kind {
        case .creditCard: return localized("额度 \(money)")
        case .income, .expense: return FinanceText.withCadence(money, entry.snapshot.effectiveCadence)
        }
    }

    private func financeDetail(_ entry: FinanceEntry) -> String {
        var parts: [String] = []
        switch entry.kind {
        case .creditCard:
            if let day = entry.statementDay { parts.append(localized("账单日 \(day) 号")) }
            if let due = FinancePlan.nextDueDate(entry.snapshot, now: now) {
                let days = FinancePlan.daysUntil(due, from: now)
                let date = due.formatted(.dateTime.month().day().locale(AppSettings.language.locale))
                parts.append(days == 0 ? localized("今天还款") : localized("\(date) 还款 · 还有 \(days) 天"))
            }
        case .income, .expense:
            if entry.cadence == .monthly, let day = entry.dayOfMonth {
                parts.append(localized("每月 \(day) 号"))
            }
            let institution = entry.institution.trimmingCharacters(in: .whitespacesAndNewlines)
            if !institution.isEmpty { parts.append(institution) }
            if entry.kind == .expense, let end = entry.endDate {
                let date = end.formatted(.dateTime.year().month().locale(AppSettings.language.locale))
                parts.append(end < now ? localized("已于 \(date) 结束") : localized("到 \(date)"))
            }
        }
        if parts.isEmpty { parts.append(updatedText(entry.updatedAt)) }
        if let name = entry.sharedAddedBy, !name.isEmpty, isShared(entry.ledgerUUID) {
            parts.append(localized("由 \(name) 添加"))
        }
        return parts.joined(separator: " · ")
    }

    private func updatedText(_ date: Date) -> String {
        let months = FinancePlan.monthsSince(date, now: now)
        return months == 0 ? localized("本月更新") : localized("\(months) 个月前更新")
    }

    private func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .appLanguage(), locale: AppSettings.language.locale)
    }

    #if DEBUG
    /// 截图验证用:--demo-assets 塞一套样板(房、车、存款、工资、年终奖、房贷、两张信用卡)。
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-assets") else { return }
        if assets.isEmpty && entries.isEmpty {
            let stale = Calendar.current.date(byAdding: .month, value: -5, to: .now) ?? .now
            func monthsAgo(_ n: Int) -> Date { Calendar.current.date(byAdding: .month, value: -n, to: .now) ?? .now }
            /// 样板的金额历史(趋势图要有几个点才看得出来)。
            func history(_ item: MemoryItem?, _ points: [(Int, Double, Double?)]) {
                guard let item else { return }
                var list = AssetHistory.decode(item.assetHistoryData)
                for (ago, value, liability) in points {
                    list = AssetHistory.appending(AssetValuePoint(date: monthsAgo(ago), value: value,
                                                                  liability: liability, currency: "CNY"), to: list)
                }
                item.assetHistoryData = AssetHistory.encode(list)
            }
            history(MemoryPipeline.saveAsset(title: "望京的房子", value: 6_800_000, liability: 2_400_000,
                                             interestRate: 3.85, category: "房产", note: "", context: context),
                    [(9, 6_500_000, 2_500_000), (4, 6_650_000, 2_450_000)])
            history(MemoryPipeline.saveAsset(title: "特斯拉 Model 3", value: 180_000, liability: 60_000,
                                             category: "车辆", note: "", context: context),
                    [(7, 210_000, 90_000), (3, 195_000, 75_000)])
            history(MemoryPipeline.saveAsset(title: "招商银行储蓄", value: 320_000, category: "存款",
                                             note: "", context: context),
                    [(5, 240_000, nil), (2, 290_000, nil)])
            history(MemoryPipeline.saveAsset(title: "住房公积金", value: 126_000, category: "公积金",
                                             note: "", context: context),
                    [(6, 102_000, nil)])
            if let parents = MemoryPipeline.saveAsset(title: "替爸妈存的定期", value: 200_000, category: "存款",
                                                      note: "", context: context) {
                parents.assetExcluded = true
            }
            let samples: [FinanceEntry] = [
                FinanceEntry(kind: .income, title: "工资", amount: 32_000, dayOfMonth: 10,
                             institution: "字节跳动", sortIndex: 0),
                FinanceEntry(kind: .income, title: "年终奖", amount: 120_000, cadence: .yearly, sortIndex: 1),
                FinanceEntry(kind: .expense, title: "房贷月供", amount: 11_800, dayOfMonth: 15,
                             institution: "建设银行",
                             endDate: Calendar.current.date(byAdding: .year, value: 22, to: .now),
                             sortIndex: 2, updatedAt: stale),
                FinanceEntry(kind: .expense, title: "车险", amount: 5_600, cadence: .yearly, sortIndex: 3),
                FinanceEntry(kind: .expense, title: "吃饭", amount: 4_000, estimated: true, sortIndex: 6),
                FinanceEntry(kind: .expense, title: "日常开销", amount: 3_000, estimated: true, sortIndex: 7),
                FinanceEntry(kind: .creditCard, title: "经典白", amount: 80_000, dayOfMonth: 20,
                             statementDay: 3, institution: "招商银行", sortIndex: 4),
                FinanceEntry(kind: .creditCard, title: "Visa 白金", amount: 50_000, dayOfMonth: 8,
                             statementDay: 18, institution: "中信银行", sortIndex: 5),
            ]
            samples.forEach(context.insert)
            try? context.save()
            FinanceReminders.sync(context: context)
        }
        // --demo-assets-tab income|expense|stats:直接切到某一档。
        if let index = args.firstIndex(of: "--demo-assets-tab"), index + 1 < args.count {
            switch args[index + 1] {
            case "income": tab = .income
            case "expense": tab = .expense
            case "stats": tab = .stats
            default: tab = .all
            }
        }
        if args.contains("--demo-assets-card") {
            editingEntry = FinanceSheet(kind: .creditCard, entry: entries(.creditCard).first)
        }
        if args.contains("--demo-assets-share") {
            showingShare = true
        }
        if args.contains("--demo-assets-new-asset") {
            editingAsset = AssetSheet(item: nil, category: "车辆")
        }
    }
    #endif
}

/// 编辑哪一项资产(nil = 新建,带着从「+」里选的分类)。
private struct AssetSheet: Identifiable {
    let item: MemoryItem?
    let category: String
    var id: String { item?.uuid.uuidString ?? "new-\(category)" }
}

private struct FinanceSheet: Identifiable {
    let kind: FinanceKind
    let entry: FinanceEntry?
    var estimated = false
    var id: String { entry?.uuid.uuidString ?? "new-\(kind.rawValue)\(estimated ? "-estimated" : "")" }
}

/// 顶上的四档切换。只是这一页的视图状态,不存。
private enum AssetTab: CaseIterable {
    case all, income, expense, stats

    var title: LocalizedStringKey {
        switch self {
        case .all: "全部"
        case .income: "收入"
        case .expense: "支出"
        case .stats: "统计"
        }
    }
}

/// 资产页的一行:图标、标题 + 一行摘要、右边金额。超过 3 个月没更新的在摘要前
/// 挂一枚小钟;开了还款提醒的信用卡挂一枚铃铛。
private struct FinanceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let amount: String?
    let amountColor: Color
    var stale = false
    var reminding = false
    var shared = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if shared {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("在共享台账里")
                    }
                    if reminding {
                        Image(systemName: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("还款提醒已开启")
                    }
                }
                HStack(spacing: 4) {
                    if stale {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("很久没更新了")
                    }
                    Text(detail).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let amount {
                Text(amount)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// 资产页里拼出来的几段文字(视图外拼的一律带 `bundle: .appLanguage()`,见 CLAUDE.md)。
enum FinanceText {
    private static var locale: Locale { AppSettings.language.locale }

    /// 信用卡显示成「招商银行 经典白」,收入/支出就是标题。
    static func displayTitle(_ entry: FinanceEntry) -> String {
        guard entry.kind == .creditCard else { return entry.title }
        let parts = [entry.institution, entry.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? entry.title : parts.joined(separator: " ")
    }

    static func withCadence(_ money: String, _ cadence: FinanceCadence) -> String {
        switch cadence {
        case .monthly: return String(localized: "\(money)/月", bundle: .appLanguage(), locale: locale)
        case .quarterly: return String(localized: "\(money)/季", bundle: .appLanguage(), locale: locale)
        case .yearly: return String(localized: "\(money)/年", bundle: .appLanguage(), locale: locale)
        case .irregular: return money
        }
    }
}
