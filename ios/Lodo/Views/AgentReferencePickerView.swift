import SwiftUI
import SwiftData
import LodoCore

/// AI 对话「+」菜单里「引用」那一组的分类。资产页的两种数据(资产/负债条目和
/// 收入/支出/信用卡)在同一个分类下分两段,和资产页本身一致。
enum AgentReferenceCategory: String, CaseIterable, Identifiable {
    case task, countdown, trip, assets, contact, menu, news

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .task: return "任务"
        case .countdown: return "倒数日"
        case .trip: return "旅行"
        case .assets: return "资产"
        case .contact: return "人脉"
        case .menu: return "菜单"
        case .news: return "新闻"
        }
    }

    var symbol: String {
        switch self {
        case .task: return AgentReferenceKind.task.symbol
        case .countdown: return AgentReferenceKind.countdown.symbol
        case .trip: return AgentReferenceKind.trip.symbol
        case .assets: return AgentReferenceKind.asset.symbol
        case .contact: return AgentReferenceKind.contact.symbol
        case .menu: return AgentReferenceKind.menu.symbol
        case .news: return AgentReferenceKind.news.symbol
        }
    }

    var pickerTitle: LocalizedStringResource {
        switch self {
        case .task: return "选择任务"
        case .countdown: return "选择倒数日"
        case .trip: return "选择旅行"
        case .assets: return "选择资产"
        case .contact: return "选择人脉"
        case .menu: return "选择菜单"
        case .news: return "选择新闻"
        }
    }

    var emptyTitle: LocalizedStringKey {
        switch self {
        case .task: return "还没有任务"
        case .countdown: return "还没有倒数日"
        case .trip: return "还没有旅行"
        case .assets: return "还没有资产"
        case .contact: return "还没有人脉"
        case .menu: return "还没有菜单"
        case .news: return "还没有新闻"
        }
    }
}

/// 一行可选的条目。
struct AgentReferenceRow: Identifiable {
    let reference: AgentReference
    let subtitle: String
    var symbol: String? = nil

    var id: UUID { reference.id }

    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || reference.title.localizedStandardContains(trimmed)
            || subtitle.localizedStandardContains(trimmed)
    }
}

struct AgentReferenceSection: Identifiable {
    let title: LocalizedStringKey?
    let rows: [AgentReferenceRow]
    let id: String
}

/// 从 app 里挑几条任务/旅行/资产…当这条消息的引用,结构同 `MemoryPickerView`:
/// 搜索 + 点选,「添加」一次性回传(选择态只存在这个 sheet 里)。
struct AgentReferencePickerView: View {
    let category: AgentReferenceCategory
    /// 已经在待发送附件里的条目,这里不再列出,避免重复引用同一条。
    let excluding: Set<UUID>
    let onDone: ([AgentReference]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// 按点选顺序排(发出去的顺序和用户点的顺序一致)。
    @State private var selected: [AgentReference] = []

    var body: some View {
        NavigationStack {
            rows
                .searchable(text: $query, prompt: Text("搜索"))
                .pageTitle(category.pickerTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "添加" : "添加(\(selected.count))") {
                            onDone(selected)
                            dismiss()
                        }
                        .disabled(selected.isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        let list = ReferenceList(category: category, query: query, excluding: excluding,
                                 selected: $selected)
        switch category {
        case .task: TaskReferenceSource(list: list)
        case .countdown: CountdownReferenceSource(list: list)
        case .trip: TripReferenceSource(list: list)
        case .assets: AssetReferenceSource(list: list)
        case .contact: MemoryReferenceSource(list: list, kind: .contact)
        case .menu: MemoryReferenceSource(list: list, kind: .menu)
        case .news: NewsReferenceSource(list: list)
        }
    }
}

// MARK: - 列表

/// 各分类共用的列表本体;数据由下面几个 *ReferenceSource 各自 @Query 好传进来。
private struct ReferenceList {
    let category: AgentReferenceCategory
    let query: String
    let excluding: Set<UUID>
    @Binding var selected: [AgentReference]

    func callAsFunction(_ sections: [AgentReferenceSection]) -> some View {
        let visible = sections.map { section in
            AgentReferenceSection(
                title: section.title,
                rows: section.rows.filter { !excluding.contains($0.id) && $0.matches(query) },
                id: section.id)
        }.filter { !$0.rows.isEmpty }
        let isEmpty = sections.allSatisfy(\.rows.isEmpty)
        return List {
            ForEach(visible) { section in
                Section {
                    ForEach(section.rows) { row in
                        Button {
                            toggle(row.reference)
                        } label: {
                            label(for: row)
                        }
                        .pressableCard()
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .overlay {
            if isEmpty {
                ContentUnavailableView(category.emptyTitle, systemImage: category.symbol)
                    .emptyStateFill()
            } else if visible.isEmpty {
                ContentUnavailableView("没有匹配的内容", systemImage: "magnifyingglass")
                    .emptyStateFill()
            }
        }
    }

    private func label(for row: AgentReferenceRow) -> some View {
        let isSelected = selected.contains { $0.id == row.id }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbol ?? row.reference.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.reference.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .font(.title3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func toggle(_ reference: AgentReference) {
        if let index = selected.firstIndex(where: { $0.id == reference.id }) {
            selected.remove(at: index)
        } else {
            selected.append(reference)
        }
    }
}

private func dateText(_ date: Date, time: Bool = false) -> String {
    time ? date.formatted(.dateTime.month().day().hour().minute())
         : date.formatted(.dateTime.year().month().day())
}

// MARK: - 各分类的数据

private struct TaskReferenceSource: View {
    let list: ReferenceList
    @Query(sort: \TaskItem.nextRemindAt) private var tasks: [TaskItem]

    var body: some View {
        let pending = tasks.filter { $0.status == .pending }
        // 已完成的只列最近完成的一批:翻几百条历史找一条不如直接问 AI。
        let done = tasks.filter { $0.status == .done }
            .sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
            .prefix(50)
        list([
            AgentReferenceSection(title: "未完成", rows: pending.map(row), id: "pending"),
            AgentReferenceSection(title: "已完成", rows: done.map(row), id: "done"),
        ])
    }

    private func row(_ task: TaskItem) -> AgentReferenceRow {
        AgentReferenceRow(reference: AgentReference(kind: .task, id: task.uuid, title: task.title),
                          subtitle: [task.caption, task.project ?? ""].filter { !$0.isEmpty }
                              .joined(separator: " · "))
    }
}

private struct CountdownReferenceSource: View {
    let list: ReferenceList
    @Query(sort: \CountdownEvent.startDate) private var events: [CountdownEvent]

    var body: some View {
        list([
            AgentReferenceSection(title: nil, rows: events.filter { !$0.archived }.map(row), id: "active"),
            AgentReferenceSection(title: "已归档", rows: events.filter(\.archived).map(row), id: "archived"),
        ])
    }

    private func row(_ event: CountdownEvent) -> AgentReferenceRow {
        var subtitle = dateText(event.startDate, time: !event.allDay)
        if let end = event.endDate { subtitle += " – " + dateText(end, time: !event.allDay) }
        return AgentReferenceRow(
            reference: AgentReference(kind: .countdown, id: event.uuid, title: event.title),
            subtitle: subtitle)
    }
}

private struct TripReferenceSource: View {
    let list: ReferenceList
    @Query(sort: \TravelTrip.startDate, order: .reverse) private var trips: [TravelTrip]

    var body: some View {
        list([AgentReferenceSection(title: nil, rows: trips.map(row), id: "trips")])
    }

    private func row(_ trip: TravelTrip) -> AgentReferenceRow {
        AgentReferenceRow(
            reference: AgentReference(kind: .trip, id: trip.uuid, title: trip.title),
            subtitle: dateText(trip.startDate) + " – " + dateText(trip.endDate))
    }
}

private struct AssetReferenceSource: View {
    let list: ReferenceList
    @Query(sort: \MemoryItem.title) private var items: [MemoryItem]
    @Query(sort: \FinanceEntry.sortIndex) private var finances: [FinanceEntry]

    var body: some View {
        list([
            AgentReferenceSection(title: "资产与负债", rows: items.filter(\.isAsset).map(assetRow), id: "assets"),
            AgentReferenceSection(title: "收入、支出与信用卡", rows: finances.map(financeRow), id: "finance"),
        ])
    }

    private func assetRow(_ item: MemoryItem) -> AgentReferenceRow {
        let category = AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames)
        var subtitle = category
        if let value = item.assetValue {
            subtitle += " · " + value.formatted(.number.precision(.fractionLength(0...2)))
                + " " + item.assetCurrencyOrDefault
        }
        return AgentReferenceRow(
            reference: AgentReference(kind: .asset, id: item.uuid, title: item.title),
            subtitle: subtitle, symbol: AssetCategory.symbol(for: category))
    }

    private func financeRow(_ entry: FinanceEntry) -> AgentReferenceRow {
        var parts: [String] = []
        if !entry.institution.isEmpty { parts.append(entry.institution) }
        if let amount = entry.amount {
            parts.append(amount.formatted(.number.precision(.fractionLength(0...2))) + " " + entry.currency)
        }
        let symbol: String = switch entry.kind {
        case .income: "arrow.down.circle"
        case .expense: "arrow.up.circle"
        case .creditCard: "creditcard"
        }
        return AgentReferenceRow(
            reference: AgentReference(kind: .finance, id: entry.uuid, title: entry.title),
            subtitle: parts.joined(separator: " · "), symbol: symbol)
    }
}

/// 人脉、菜单:都是打了保留标签的记忆条目。
private struct MemoryReferenceSource: View {
    let list: ReferenceList
    let kind: AgentReferenceKind
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)]) private var items: [MemoryItem]

    var body: some View {
        let matching = kind == .contact
            ? items.filter(\.isContact).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            : items.filter(\.isMenu)
        list([AgentReferenceSection(title: nil, rows: matching.map(row), id: kind.rawValue)])
    }

    private func row(_ item: MemoryItem) -> AgentReferenceRow {
        let subtitle: String
        if kind == .contact {
            subtitle = [item.contactNickname, item.contactPhone, item.contactEmail]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            subtitle = dateText(item.createdAt)
        }
        return AgentReferenceRow(
            reference: AgentReference(kind: kind, id: item.uuid, title: item.title),
            subtitle: subtitle)
    }
}

private struct NewsReferenceSource: View {
    let list: ReferenceList
    @Query private var articles: [NewsArticle]

    init(list: ReferenceList) {
        self.list = list
        // 新闻会攒很多,只列最近的一批;更早的直接问 AI(它能搜本机所有文章)。
        var descriptor = FetchDescriptor<NewsArticle>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = 200
        _articles = Query(descriptor)
    }

    var body: some View {
        list([
            AgentReferenceSection(title: "已收藏", rows: articles.filter(\.isStarred).map(row), id: "starred"),
            AgentReferenceSection(title: "最近", rows: articles.filter { !$0.isStarred }.map(row), id: "recent"),
        ])
    }

    private func row(_ article: NewsArticle) -> AgentReferenceRow {
        AgentReferenceRow(
            reference: AgentReference(kind: .news, id: article.uuid, title: article.title),
            subtitle: article.feedTitle + " · " + dateText(article.publishedAt, time: true))
    }
}
