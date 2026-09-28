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
/// 顶上是总览卡:净资产 + 每月收支;有哪一项超过 3 个月没更新就挂一行提示。
/// 新建收在右上角「+」——收入/支出/信用卡 AI 接不了(同人脉页右上角那两颗的道理)。
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

    private var rates: ExchangeRateStore { ExchangeRateStore.shared }

    private var assets: [MemoryItem] {
        memoryItems.filter(\.isAsset).sorted { $0.createdAt < $1.createdAt }
    }

    private func entries(_ kind: FinanceKind) -> [FinanceEntry] {
        entries.filter { $0.kind == kind }
    }

    private var isEmpty: Bool { assets.isEmpty && entries.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                if isEmpty {
                    emptyState
                } else {
                    Section { overviewCard }
                    assetSections
                    financeSection(.income)
                    financeSection(.expense)
                    financeSection(.creditCard)
                }
            }
            .navigationTitle("资产")
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false) {
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
                FinanceEntryEditView(kind: sheet.kind, existing: sheet.entry)
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

    // MARK: - 新建

    private var addMenu: some View {
        Menu {
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
                    editingEntry = FinanceSheet(kind: .creditCard, entry: nil)
                } label: { Label("信用卡", systemImage: "creditcard") }
            }
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("还没有记过资产", systemImage: "banknote")
            } description: {
                Text("记下房子、车子、存款,每月的收入和固定支出,还有信用卡。不用记日常花销,隔几个月回来更新一次就好。")
            } actions: {
                addMenu
                    .buttonStyle(.borderedProminent)
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 总览

    private var netWorth: FinancePlan.NetWorth {
        FinancePlan.netWorth(
            assets.map { (value: $0.assetValue, liability: $0.assetLiability,
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
        let dates = assets.map(\.assetUpdatedAtOrCreated) + entries.map(\.updatedAt)
        return dates.filter { FinancePlan.monthsSince($0, now: now) >= FinancePlan.staleMonths }.count
    }

    private var overviewCard: some View {
        let worth = netWorth
        let month = monthly
        return VStack(alignment: .leading, spacing: 12) {
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
            if !entries(.income).isEmpty || !entries(.expense).isEmpty {
                Divider()
                HStack(alignment: .top) {
                    monthlyFigure("每月收入", month.income, color: LodoColor.positive)
                    monthlyFigure("固定支出", month.expense, color: LodoColor.critical)
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
                           >= FinancePlan.staleMonths)
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

    private func assetDetail(_ item: MemoryItem) -> String {
        var parts: [String] = []
        if let liability = item.assetLiability {
            parts.append(localized("负债 \(AssetFormat.currency(liability, code: item.assetCurrencyOrDefault))"))
        }
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
            editingEntry = FinanceSheet(kind: entry.kind, entry: entry)
        } label: {
            FinanceRow(symbol: symbol(for: entry),
                       title: FinanceText.displayTitle(entry),
                       detail: financeDetail(entry),
                       amount: amountText(entry),
                       amountColor: entry.kind == .income ? LodoColor.positive
                           : entry.kind == .expense ? LodoColor.critical : .primary,
                       stale: FinancePlan.monthsSince(entry.updatedAt, now: now) >= FinancePlan.staleMonths,
                       reminding: entry.kind == .creditCard && entry.remindEnabled && entry.dayOfMonth != nil)
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
        case .expense: return "arrow.up.circle.fill"
        case .creditCard: return "creditcard.fill"
        }
    }

    private func amountText(_ entry: FinanceEntry) -> String? {
        guard let amount = entry.amount else { return nil }
        let money = AssetFormat.currency(amount, code: entry.currency)
        switch entry.kind {
        case .creditCard: return localized("额度 \(money)")
        case .income, .expense: return FinanceText.withCadence(money, entry.cadence)
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
            MemoryPipeline.saveAsset(title: "望京的房子", value: 6_800_000, liability: 2_400_000,
                                     interestRate: 3.85, category: "房产", note: "", context: context)
            MemoryPipeline.saveAsset(title: "特斯拉 Model 3", value: 180_000, category: "车辆",
                                     note: "", context: context)
            MemoryPipeline.saveAsset(title: "招商银行储蓄", value: 320_000, category: "存款",
                                     note: "", context: context)
            let samples: [FinanceEntry] = [
                FinanceEntry(kind: .income, title: "工资", amount: 32_000, dayOfMonth: 10,
                             institution: "字节跳动", sortIndex: 0),
                FinanceEntry(kind: .income, title: "年终奖", amount: 120_000, cadence: .yearly, sortIndex: 1),
                FinanceEntry(kind: .expense, title: "房贷月供", amount: 11_800, dayOfMonth: 15,
                             institution: "建设银行",
                             endDate: Calendar.current.date(byAdding: .year, value: 22, to: .now),
                             sortIndex: 2, updatedAt: stale),
                FinanceEntry(kind: .expense, title: "车险", amount: 5_600, cadence: .yearly, sortIndex: 3),
                FinanceEntry(kind: .creditCard, title: "经典白", amount: 80_000, dayOfMonth: 20,
                             statementDay: 3, institution: "招商银行", sortIndex: 4),
                FinanceEntry(kind: .creditCard, title: "Visa 白金", amount: 50_000, dayOfMonth: 8,
                             statementDay: 18, institution: "中信银行", sortIndex: 5),
            ]
            samples.forEach(context.insert)
            try? context.save()
            FinanceReminders.sync(context: context)
        }
        if args.contains("--demo-assets-card") {
            editingEntry = FinanceSheet(kind: .creditCard, entry: entries(.creditCard).first)
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
    var id: String { entry?.uuid.uuidString ?? "new-\(kind.rawValue)" }
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
