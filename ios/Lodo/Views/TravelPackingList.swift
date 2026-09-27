import SwiftUI
import SwiftData
import LodoCore

/// 旅行详情面板里的「清单」:这次旅行要带的东西,点一下勾成"已装好"。
/// 手动加一件,或者让 AI 按目的地、季节、行程建议一份——**AI 的建议先摆出来让人
/// 勾选,点了「加入清单」才落库**(同 plan_trip 的取舍:建议不是事实,护照带没带
/// 用户自己最清楚)。
///
/// 数据是独立的轻量模型 `PackingItem`(靠 tripUUID 关联),不进记忆库,理由见模型注释。
struct TravelPackingList: View {
    let trip: TravelTrip

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    @Query private var allItems: [PackingItem]
    @Query private var memoryItems: [MemoryItem]

    @State private var newTitle = ""
    @FocusState private var addFocused: Bool
    @State private var suggesting = false
    @State private var suggestError: String?
    @State private var suggestions: [PackingSuggestion]?

    private var items: [PackingItem] { allItems.filter { $0.tripUUID == trip.uuid } }
    private var packedCount: Int { items.filter(\.packed).count }

    var body: some View {
        List {
            Section {
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已装好 \(packedCount) / \(items.count)")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                        ProgressView(value: Double(packedCount), total: Double(max(items.count, 1)))
                    }
                    .padding(.vertical, 2)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                    TextField("添加要带的东西", text: $newTitle)
                        .focused($addFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                }
                Button(action: suggest) {
                    HStack(spacing: 8) {
                        if suggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(suggesting ? "AI 正在想要带什么…" : "AI 建议清单")
                            .font(.body.weight(.medium))
                    }
                }
                .disabled(suggesting)
            } footer: {
                if let suggestError {
                    Text(suggestError).foregroundStyle(LodoColor.critical)
                } else if items.isEmpty {
                    Text("按目的地、季节和行程,让 AI 先列一份,再挑着加进来。")
                }
            }
            .listRowBackground(TravelDetailView.panelRowBackground)

            ForEach(PackingPlan.grouped(items), id: \.category) { group in
                Section {
                    ForEach(group.items) { item in row(item) }
                } header: {
                    Text(group.category.isEmpty
                         ? String(localized: "其他", locale: language.locale) : group.category)
                }
                .listRowBackground(TravelDetailView.panelRowBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: Binding(
            get: { suggestions.map(SuggestionBatch.init) },
            set: { if $0 == nil { suggestions = nil } })) { batch in
            PackingSuggestionSheet(suggestions: batch.items) { picked in
                insert(picked)
            }
        }
    }

    private func row(_ item: PackingItem) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.lodoAware(.snappy)) {
                item.packed.toggle()
                try? context.save()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.packed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.packed ? AnyShapeStyle(LodoColor.positive)
                                                 : AnyShapeStyle(.secondary))
                Text(item.title)
                    .foregroundStyle(item.packed ? .secondary : .primary)
                    .strikethrough(item.packed)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityAddTraits(item.packed ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                context.delete(item)
                try? context.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        context.insert(PackingItem(tripUUID: trip.uuid, title: title,
                                   category: String(localized: "其他", locale: language.locale),
                                   sortIndex: nextIndex))
        try? context.save()
        newTitle = ""
        addFocused = true
    }

    private var nextIndex: Int { (items.map(\.sortIndex).max() ?? -1) + 1 }

    private func insert(_ picked: [PackingSuggestion]) {
        var index = nextIndex
        for suggestion in picked {
            context.insert(PackingItem(tripUUID: trip.uuid, title: suggestion.title,
                                       category: suggestion.category, sortIndex: index))
            index += 1
        }
        try? context.save()
    }

    private func suggest() {
        suggesting = true
        suggestError = nil
        let entries = TravelStore.entries(for: trip.uuid, from: memoryItems)
        var summary = TravelPlan.promptSummary(tripTitle: trip.title, days: trip.days,
                                               entries: entries)
        if let location = trip.locationText { summary = "目的地:\(location)\n" + summary }
        let dates = trip.days.first.map {
            "日期:\($0.formatted(.iso8601.year().month().day())) 起 \(trip.dayCount) 天\n"
        } ?? ""
        let existing = items.map(\.title)
        let languageName = MenuStore.targetLanguageName(language)
        Task {
            do {
                let result = try await DeepSeekClient.suggestPackingList(
                    summary: dates + summary, existing: existing, language: languageName)
                let fresh = PackingPlan.newSuggestions(result, existing: existing)
                if fresh.isEmpty {
                    suggestError = String(localized: "AI 没有想到清单里还缺什么。",
                                          locale: language.locale)
                } else {
                    suggestions = fresh
                }
            } catch {
                suggestError = error.localizedDescription
            }
            suggesting = false
        }
    }
}

/// sheet(item:) 需要 Identifiable;一次建议就是一批。
private struct SuggestionBatch: Identifiable {
    let items: [PackingSuggestion]
    var id: String { items.map(\.id).joined() }
}

/// AI 建议的清单:默认全选,取消勾掉不要的,点「加入清单」。
private struct PackingSuggestionSheet: View {
    let suggestions: [PackingSuggestion]
    let onAdd: ([PackingSuggestion]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var didLoad = false

    private var groups: [(category: String, items: [PackingSuggestion])] {
        var order: [String] = []
        var buckets: [String: [PackingSuggestion]] = [:]
        for suggestion in suggestions {
            if buckets[suggestion.category] == nil { order.append(suggestion.category) }
            buckets[suggestion.category, default: []].append(suggestion)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.items) { suggestion in
                            Button {
                                if selected.contains(suggestion.id) {
                                    selected.remove(suggestion.id)
                                } else {
                                    selected.insert(suggestion.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected.contains(suggestion.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selected.contains(suggestion.id)
                                                         ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title).foregroundStyle(.primary)
                                        if !suggestion.reason.isEmpty {
                                            Text(suggestion.reason)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .pressableCard()
                            .accessibilityAddTraits(selected.contains(suggestion.id)
                                                    ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("AI 建议")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("加入清单") {
                        onAdd(suggestions.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                selected = Set(suggestions.map(\.id))
            }
        }
        .presentationDetents([.medium, .large])
    }
}
