import SwiftUI
import SwiftData
import LodoCore

/// 订阅管理:已订阅的源(改名/改类别/停用/删除)+ 推荐订阅一键添加。
struct NewsFeedsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.accentPaletteKey) private var accentPaletteRaw =
        AccentPalette.terracotta.rawValue
    @Query(sort: [SortDescriptor(\NewsFeed.createdAt)]) private var feeds: [NewsFeed]

    @State private var showAdd = false
    @State private var editing: NewsFeed?
    @State private var pendingDelete: NewsFeed?
    @State private var addingPreset: String?
    @State private var presetError: String?

    private var accentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .terracotta
    }

    private var availablePresets: [NewsStore.Preset] {
        NewsStore.presets.filter { preset in !feeds.contains { $0.url == preset.url } }
    }

    var body: some View {
        List {
            Section {
                if feeds.isEmpty {
                    Text("还没有订阅。点右上角添加,或者从下面的推荐里挑几个。")
                        .foregroundStyle(.secondary)
                }
                ForEach(feeds) { feed in
                    Button {
                        editing = feed
                    } label: {
                        row(feed)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = feed
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            feed.enabled.toggle()
                            try? context.save()
                        } label: {
                            Label(feed.enabled ? "停用" : "启用",
                                  systemImage: feed.enabled ? "pause.circle" : "play.circle")
                        }
                        .tint(LodoColor.neutralAction)
                    }
                }
            } header: {
                Text("已订阅")
            } footer: {
                if !feeds.isEmpty {
                    Text("停用的订阅不再抓取新文章,已经抓到的留着。删除订阅会连同它的文章一起删掉,收藏过的除外。")
                }
            }

            if !availablePresets.isEmpty {
                Section {
                    ForEach(availablePresets) { preset in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                    Text(URL(string: preset.url)?.host ?? preset.url)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: preset.kind.symbol)
                            }
                            Spacer()
                            if addingPreset == preset.url {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    subscribe(preset)
                                } label: {
                                    Label("订阅", systemImage: "plus.circle")
                                        .labelStyle(.iconOnly)
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .pressable()
                                .disabled(addingPreset != nil)
                            }
                        }
                    }
                } header: {
                    Text("推荐订阅")
                } footer: {
                    if let presetError {
                        Text(presetError).foregroundStyle(LodoColor.critical)
                    }
                }
            }
        }
        .navigationTitle("管理订阅")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            NewsFeedAddView()
                .tint(accentPalette.accent)
                .environment(\.lodoAccent, accentPalette)
        }
        .sheet(item: $editing) { feed in
            NewsFeedEditView(feed: feed)
                .tint(accentPalette.accent)
                .environment(\.lodoAccent, accentPalette)
        }
        .alert("删除这个订阅?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let feed = pendingDelete { NewsStore.delete(feed, context: context) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("它的文章会一起删掉,收藏过的会留下。")
        }
    }

    private func row(_ feed: NewsFeed) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feed.kind.symbol)
                .foregroundStyle(feed.enabled ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(feed.enabled ? .primary : .secondary)
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(feed.kind.title))
                    Text("·")
                    Text(URL(string: feed.url)?.host ?? feed.url).lineLimit(1)
                    if !feed.enabled {
                        Text("·")
                        Text("已停用")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let error = feed.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(LodoColor.critical)
                        .lineLimit(2)
                } else if let last = feed.lastFetchedAt {
                    Text("更新于 \(last, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func subscribe(_ preset: NewsStore.Preset) {
        addingPreset = preset.url
        presetError = nil
        Task {
            do {
                try await NewsStore.subscribe(preset.url, kind: preset.kind, context: context)
            } catch {
                presetError = "「\(preset.title)」订阅失败:\(error.localizedDescription)"
            }
            addingPreset = nil
        }
    }
}

/// 添加订阅:填 RSS 地址或博客首页(自动找订阅地址),选类别。
struct NewsFeedAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var address = ""
    @State private var kind: NewsFeedKind = .news
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("网址,如 sspai.com/feed", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                    Picker("类别", selection: $kind) {
                        ForEach(NewsFeedKind.allCases, id: \.self) { kind in
                            Text(LocalizedStringKey(kind.title)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("可以直接填 RSS/Atom 订阅地址;订阅博客时填博客首页也行,会自动找到它的订阅地址。")
                        if let errorText {
                            Text(errorText).foregroundStyle(LodoColor.critical)
                        }
                    }
                }
            }
            .navigationTitle("添加订阅")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if task != nil {
                        ProgressView()
                    } else {
                        Button("订阅", action: submit)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard task == nil else { return }
        errorText = nil
        task = Task {
            do {
                try await NewsStore.subscribe(address, kind: kind, context: context)
                dismiss()
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
            task = nil
        }
    }
}

/// 改一个订阅:名字和类别。
struct NewsFeedEditView: View {
    let feed: NewsFeed

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title: String
    @State private var kind: NewsFeedKind

    init(feed: NewsFeed) {
        self.feed = feed
        _title = State(initialValue: feed.title)
        _kind = State(initialValue: feed.kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $title)
                    Picker("类别", selection: $kind) {
                        ForEach(NewsFeedKind.allCases, id: \.self) { kind in
                            Text(LocalizedStringKey(kind.title)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("订阅地址") {
                    Text(feed.url)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let site = URL(string: feed.siteURL), !feed.siteURL.isEmpty {
                        Link(destination: site) {
                            Label("打开网站", systemImage: "safari")
                        }
                    }
                }
            }
            .navigationTitle("编辑订阅")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        feed.kind = kind
                        NewsStore.rename(feed, to: title, context: context)
                        try? context.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
