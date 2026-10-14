import SwiftUI
import SwiftData
import Charts
import LodoCore

/// 视图外拼的文案按应用内语言取(见 `Bundle.appLanguage` 的注释)。
private func checkupLoc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .appLanguage(), locale: AppSettings.language.locale)
}

/// 档案的显示名:本人(nil)是「我」,家人用 TA 的名字。
func checkupProfileName(_ id: UUID?, in profiles: [HealthProfile]) -> String {
    guard let id else { return checkupLoc("我") }
    return profiles.first(where: { $0.uuid == id })?.name ?? checkupLoc("家人")
}

private let checkupDayFormat = Date.FormatStyle.dateTime.year().month().day()

// MARK: - 健康页里的「体检档案」一组

/// 健康页上的入口:本人 + 每位家人一行,下面是上传报告/添加家人两个按钮。
/// 新建的报告整理完直接 push 进报告详情(`openReport` 由健康页挂 navigationDestination)。
struct CheckupSection: View {
    /// 健康页手里那份记忆条目 @Query(不另开一份)。
    let memoryItems: [MemoryItem]
    @Binding var openReport: UUID?

    @Query(sort: \HealthProfile.createdAt) private var profiles: [HealthProfile]
    @State private var showImport = false
    @State private var showAddProfile = false

    var body: some View {
        Section {
            NavigationLink {
                CheckupProfileView(profileID: nil)
            } label: {
                profileRow(name: Text("我"), relation: nil, profileID: nil, systemImage: "person.crop.circle")
            }
            ForEach(profiles) { profile in
                NavigationLink {
                    CheckupProfileView(profileID: profile.uuid)
                } label: {
                    profileRow(name: Text(profile.name), relation: profile.relation,
                               profileID: profile.uuid, systemImage: "person.circle")
                }
            }
            Button {
                showImport = true
            } label: {
                Label("上传体检报告", systemImage: "doc.badge.plus")
            }
            Button {
                showAddProfile = true
            } label: {
                Label("添加家人档案", systemImage: "person.badge.plus")
            }
        } header: {
            // sheet 挂在 header 上:挂在 Section 上会分摊到每一行(见空气质量那组)。
            Text("体检档案")
                .sheet(isPresented: $showImport) {
                    CheckupImportView(initialProfile: nil) { openReport = $0.uuid }
                }
                .sheet(isPresented: $showAddProfile) {
                    HealthProfileEditView(profile: nil)
                }
        } footer: {
            Text("本人的体检结果会作为 AI 健康分析的参考;家人的档案只做记录和分享,不参与分析。")
        }
    }

    private func profileRow(name: Text, relation: String?, profileID: UUID?,
                            systemImage: String) -> some View {
        let reports = CheckupStore.reports(of: profileID, in: memoryItems)
        return HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    name.font(.body.weight(.medium))
                    if let relation, !relation.isEmpty {
                        Text(relation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let profileID, profiles.first(where: { $0.uuid == profileID })?.isShared == true {
                        Image(systemName: "person.2.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("已共享"))
                    }
                }
                Group {
                    if let latest = reports.first {
                        Text("\(reports.count) 份报告 · 最近 \(CheckupStore.date(of: latest), format: checkupDayFormat)")
                    } else {
                        Text("还没有报告")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 一个人的档案

/// 要 push 的家人档案(包一层,和报告的 `UUID?` 跳转分开)。
struct CheckupProfileTarget: Hashable, Identifiable {
    let id: UUID
}

/// 时间轴的两种看法。rawValue 存本机偏好,别改。
private enum CheckupTimelineMode: String, CaseIterable {
    case reports
    case metrics
}

/// 一个人的体检档案:按报告看(每份报告一行)/ 按指标看(每项指标一行,点进去看变化)。
struct CheckupProfileView: View {
    let profileID: UUID?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HealthProfile.createdAt) private var profiles: [HealthProfile]
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query private var allEntries: [CheckupEntry]
    @AppStorage("checkupTimelineMode") private var modeRaw = CheckupTimelineMode.reports.rawValue

    @State private var showImport = false
    @State private var showNormalize = false
    @State private var editingProfile = false
    @State private var openReport: UUID?
    @State private var shareFiles: ShareFiles?
    @State private var shareError: String?
    /// 正在建 zone / 取 share(第一次共享要等几秒)。
    @State private var preparingCloudShare = false
    private let sync = SharedTripSync.shared

    private struct ShareFiles: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    private var mode: CheckupTimelineMode { CheckupTimelineMode(rawValue: modeRaw) ?? .reports }
    private var profile: HealthProfile? { profiles.first { $0.uuid == profileID } }
    private var name: String { checkupProfileName(profileID, in: profiles) }
    private var reports: [MemoryItem] { CheckupStore.reports(of: profileID, in: memoryItems) }
    private var entries: [CheckupEntryValue] { CheckupStore.entries(ofProfile: profileID, in: allEntries) }

    var body: some View {
        List {
            if preparingCloudShare || profile?.isShared == true {
                shareStatusSection
            }
            if reports.isEmpty {
                ContentUnavailableView {
                    Label("还没有体检报告", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("上传 PDF 或拍下纸质报告,AI 会把指标、结论和建议整理成一条条记录。")
                } actions: {
                    Button("上传体检报告") { showImport = true }
                        .glassProminentButton()
                }
                .emptyStateFill()
            } else {
                Section {
                    Picker("查看方式", selection: $modeRaw) {
                        Text("按报告").tag(CheckupTimelineMode.reports.rawValue)
                        Text("按指标").tag(CheckupTimelineMode.metrics.rawValue)
                    }
                    .segmentedPickerStyle()
                    .standaloneSwitchLayout()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch mode {
                case .reports: reportsList
                case .metrics: metricsList
                }
                Section {
                    Button {
                        showNormalize = true
                    } label: {
                        Label("重新匹配检查项", systemImage: "arrow.triangle.merge")
                    }
                } footer: {
                    Text("把历次报告里同一项指标的不同写法(中英文、缩写、全称)合成一项,并去掉重复的记录。")
                }
            }
        }
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showImport = true
                    } label: {
                        Label("上传体检报告", systemImage: "doc.badge.plus")
                    }
                    if let profile {
                        // 家人档案经 iCloud 共享给别人一起维护(本人的档案不能共享)。
                        Button {
                            shareViaCloud(profile)
                        } label: {
                            Label(profile.isShared ? "共享成员…" : "共享档案…", systemImage: "person.2")
                        }
                        .disabled(preparingCloudShare || !sync.isAvailable)
                    }
                    Button {
                        showNormalize = true
                    } label: {
                        Label("重新匹配检查项", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(reports.isEmpty)
                    Button {
                        prepareShare()
                    } label: {
                        Label("导出为文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(reports.isEmpty)
                    if profile != nil {
                        Button {
                            editingProfile = true
                        } label: {
                            Label("编辑家人信息", systemImage: "pencil")
                        }
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(item: $openReport) { CheckupReportView(reportID: $0) }
        .sheet(isPresented: $showImport) {
            CheckupImportView(initialProfile: profileID) { openReport = $0.uuid }
        }
        .sheet(isPresented: $editingProfile) {
            if let profile {
                HealthProfileEditView(profile: profile) { dismiss() }
            }
        }
        .sheet(item: $shareFiles) { files in
            CheckupShareSheet(name: name, urls: files.urls)
        }
        .sheet(isPresented: $showNormalize) {
            CheckupNormalizeView(profileID: profileID)
        }
        .alert("分享失败", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("好") {}
        } message: {
            Text(shareError ?? "")
        }
    }

    // MARK: 共享状态

    private var shareStatusSection: some View {
        Section {
            if preparingCloudShare {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(profile?.isShared == true ? "正在读取共享成员…" : "正在建立共享…")
                        .foregroundStyle(.secondary)
                }
            } else if let profile {
                HStack(spacing: 8) {
                    Label {
                        Text(profile.shareRole == .owner ? "已共享 · 我创建的" : "已共享 · 我加入的")
                    } icon: {
                        Image(systemName: "person.2.fill")
                    }
                    Spacer()
                    if let pending = sync.pendingCounts[profile.uuid], pending > 0 {
                        Text("正在同步 \(pending) 项")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("成员都可以查看、上传和修改这份档案,改动会自动同步。共享的家人档案在每个人那里都不参与 AI 健康分析。")
        }
    }

    /// 建 zone + CKShare(已共享时取回现有的),再弹系统共享界面。已有的报告和原文件
    /// 随后在后台上传。
    private func shareViaCloud(_ profile: HealthProfile) {
        preparingCloudShare = true
        Task {
            defer { preparingCloudShare = false }
            do {
                let share = try await sync.prepareShare(for: profile)
                CloudSharingPresenter.present(share: share, profile: profile)
            } catch {
                shareError = error.localizedDescription
            }
        }
    }

    // MARK: 按报告

    /// 按年分组,同一年里从近到远。
    private var reportsList: some View {
        let byYear = Dictionary(grouping: reports) {
            Calendar.current.component(.year, from: CheckupStore.date(of: $0))
        }
        return ForEach(byYear.keys.sorted(by: >), id: \.self) { year in
            Section {
                ForEach(byYear[year] ?? []) { report in
                    NavigationLink {
                        CheckupReportView(reportID: report.uuid)
                    } label: {
                        reportRow(report)
                    }
                }
            } header: {
                Text(verbatim: String(year))
            }
        }
    }

    private func reportRow(_ report: MemoryItem) -> some View {
        let values = entries.filter { $0.reportID == report.uuid }
        let abnormal = CheckupPlan.abnormalCount(values)
        return VStack(alignment: .leading, spacing: 4) {
            Text(report.title)
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                Text(CheckupStore.date(of: report), format: checkupDayFormat)
                if let institution = report.checkupInstitution {
                    Text(verbatim: "· \(institution)")
                        .lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let addedBy = report.sharedAddedBy {
                Text("由 \(addedBy) 添加")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if abnormal > 0 {
                Label {
                    Text("\(abnormal) 项异常")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(LodoColor.critical)
            }
        }
    }

    // MARK: 按指标

    private var metricsList: some View {
        let metrics = CheckupPlan.metrics(from: entries)
        var order: [String] = []
        var groups: [String: [CheckupMetric]] = [:]
        for metric in metrics {
            if groups[metric.category] == nil { order.append(metric.category) }
            groups[metric.category, default: []].append(metric)
        }
        return ForEach(order, id: \.self) { category in
            Section {
                ForEach(groups[category] ?? []) { metric in
                    NavigationLink {
                        CheckupMetricView(profileID: profileID, key: metric.key)
                    } label: {
                        metricRow(metric)
                    }
                }
            } header: {
                if category.isEmpty {
                    Text("其他")
                } else {
                    Text(category)
                }
            }
        }
    }

    private func metricRow(_ metric: CheckupMetric) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.name)
                    .font(.body.weight(.medium))
                Text("\(metric.records.count) 次记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let latest = metric.latest {
                CheckupValueText(entry: latest)
                    .lineLimit(1)
            }
        }
    }

    // MARK: 分享

    private func prepareShare() {
        do {
            shareFiles = ShareFiles(urls: try CheckupStore.shareFiles(
                profileID: profileID, name: name, context: context))
        } catch {
            shareError = error.localizedDescription
        }
    }
}

/// 「重新匹配检查项」:先算出要合并哪些写法、删哪些重复记录给用户看,点「应用」才
/// 落库。合并错了的代价是把两项指标的历史搅在一起,所以不直接执行。
private struct CheckupNormalizeView: View {
    let profileID: UUID?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var plan: CheckupNormalizationPlan?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    if plan.isEmpty {
                        ContentUnavailableView {
                            Label("没有需要合并的检查项", systemImage: "checkmark.circle")
                        } description: {
                            Text("历次报告里的检查项名称已经一致,也没有重复的记录。")
                        }
                    } else {
                        groupsSection(plan)
                        removalsSection(plan)
                    }
                } else if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(LodoColor.critical)
                        Button("重试") { start() }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在比对各次报告里的检查项…")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        if !DeepSeekClient.isConfigured {
                            Text("没有配置 AI,只按英文缩写和完全相同的名称匹配。")
                        }
                    }
                }
            }
            .pageTitle("重新匹配检查项")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if let plan { CheckupStore.apply(plan, context: context) }
                        dismiss()
                    }
                    .disabled(plan?.isEmpty ?? true)
                }
            }
        }
        .onAppear { if plan == nil { start() } }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private func groupsSection(_ plan: CheckupNormalizationPlan) -> some View {
        if !plan.groups.isEmpty {
            Section {
                ForEach(plan.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.canonical)
                            .font(.body.weight(.medium))
                        Text(group.variants.joined(separator: "、"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("共 \(group.recordCount) 次记录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("合并为同一项")
            } footer: {
                Text("下面灰色的写法会统一改成上面的名称。")
            }
        }
    }

    @ViewBuilder
    private func removalsSection(_ plan: CheckupNormalizationPlan) -> some View {
        if !plan.removals.isEmpty {
            Section {
                ForEach(plan.removals) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.date, format: checkupDayFormat)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.displayValue)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("删除重复记录")
            } footer: {
                Text("同一份报告里同一项出现了不止一次、结果也相同,只留信息最全的那条,它缺的单位、参考范围、建议从重复的那条补上。")
            }
        }
    }

    private func start() {
        errorMessage = nil
        task?.cancel()
        task = Task {
            do {
                let result = try await CheckupStore.normalizationPlan(profileID: profileID, context: context)
                guard !Task.isCancelled else { return }
                plan = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 分享前先把要发出去的东西列出来:健康资料是敏感信息,点了"分享"之后不该直接
/// 弹出系统面板让人一不小心就发进群里。
private struct CheckupShareSheet: View {
    let name: String
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(urls, id: \.self) { url in
                        Label(url.lastPathComponent,
                              systemImage: url.pathExtension == "txt" ? "doc.text" : "doc")
                            .lineLimit(1)
                    }
                } footer: {
                    Text("包括一份整理好的文字档案和每份报告的原文件。对方不需要安装 lodo 也能打开。")
                }
                Section {
                    ShareLink(items: urls) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle(name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 值的显示

/// 结果 + 单位,异常时染成警示色并带箭头。颜色只上箭头和数字,不靠颜色单独表达
/// (旁白里读得出"偏高")。
struct CheckupValueText: View {
    let entry: CheckupEntryValue

    var body: some View {
        let flag = entry.effectiveFlag
        let abnormal = flag?.isAbnormal ?? false
        HStack(spacing: 3) {
            Text(entry.displayValue.isEmpty ? "—" : entry.displayValue)
                .font(.body.monospacedDigit())
            if let flag, abnormal {
                Image(systemName: flag.symbol)
                    .font(.footnote.weight(.bold))
                    .accessibilityLabel(CheckupFlagLabel(flag: flag).text)
            }
        }
        .foregroundStyle(abnormal ? LodoColor.critical : Color.primary)
    }
}

/// 标记的文字(按应用语言取)。
struct CheckupFlagLabel {
    let flag: CheckupFlag?

    var text: Text {
        switch flag {
        case .none: return Text("未标记")
        case .normal: return Text("正常")
        case .high: return Text("偏高")
        case .low: return Text("偏低")
        case .abnormal: return Text("异常")
        }
    }
}

/// 条目行:名称 + 结论/建议在左,结果在右。报告详情和指标时间轴共用。
private struct CheckupEntryRow: View {
    let entry: CheckupEntryValue
    /// 指标时间轴里这一行的标题是日期,不是名称。
    var title: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                (title ?? Text(entry.name))
                    .font(.body.weight(.medium))
                Spacer()
                if !entry.value.isEmpty {
                    CheckupValueText(entry: entry)
                }
            }
            if !entry.referenceRange.isEmpty {
                Text("参考范围 \(entry.referenceRange)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // 结论分行显示:影像/体格检查的描述常常是好几句,挤成一行读不了。
            ForEach(Array(conclusionLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(entry.value.isEmpty && (entry.effectiveFlag?.isAbnormal ?? false)
                                     ? LodoColor.critical : Color.secondary)
            }
            if !entry.advice.isEmpty {
                Label {
                    Text(entry.advice)
                } icon: {
                    Image(systemName: "lightbulb")
                }
                .font(.subheadline)
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private var conclusionLines: [String] {
        guard !entry.conclusion.isEmpty, entry.conclusion != entry.displayValue else { return [] }
        return entry.conclusion
            .components(separatedBy: CharacterSet(charactersIn: "\n;;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 一份报告

struct CheckupReportView: View {
    let reportID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [MemoryItem]
    @Query private var entryModels: [CheckupEntry]
    @Query(sort: \HealthProfile.createdAt) private var profiles: [HealthProfile]

    @State private var previewURL: URL?
    @State private var previewFiles: [URL] = []
    @State private var editing: EntryEditing?
    @State private var editingReport = false
    @State private var confirmDelete = false

    /// 编辑哪一条:已有的,或者要新建的种类。
    private enum EntryEditing: Identifiable {
        case existing(CheckupEntry)
        case new(CheckupEntryKind)

        var id: String {
            switch self {
            case .existing(let entry): return entry.uuid.uuidString
            case .new(let kind): return "new-\(kind.rawValue)"
            }
        }
    }

    init(reportID: UUID) {
        self.reportID = reportID
        _matches = Query(filter: #Predicate<MemoryItem> { $0.uuid == reportID })
        _entryModels = Query(filter: #Predicate<CheckupEntry> { $0.reportUUID == reportID },
                             sort: \CheckupEntry.sortIndex)
    }

    private var report: MemoryItem? { matches.first }
    private var values: [CheckupEntryValue] { entryModels.map(CheckupEntryValue.init(from:)) }

    var body: some View {
        Group {
            if let report {
                content(report)
            } else {
                ContentUnavailableView("这份报告已经删除", systemImage: "doc.text")
            }
        }
        .navigationTitle(report?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func openFiles(_ report: MemoryItem) {
        previewFiles = CheckupStore.previewCopies(of: report)
        previewURL = previewFiles.first
    }

    private func content(_ report: MemoryItem) -> some View {
        let files = CheckupStore.fileURLs(of: report)
        let advice = entryModels.first { $0.kind == .advice }
        return List {
            Section {
                LabeledContent("体检日期") { Text(CheckupStore.date(of: report), format: checkupDayFormat) }
                if let institution = report.checkupInstitution {
                    LabeledContent("体检机构", value: institution)
                }
                LabeledContent("档案", value: checkupProfileName(report.checkupProfileUUID, in: profiles))
                if files.isEmpty {
                    Text("原文件不在这台设备上")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        openFiles(report)
                    } label: {
                        Label {
                            if files.count > 1 {
                                Text("查看原文件(\(files.count) 个)")
                            } else {
                                Text("查看原文件")
                            }
                        } icon: {
                            Image(systemName: "doc.viewfinder")
                        }
                    }
                }
            }

            Section {
                if let advice {
                    Button {
                        editing = .existing(advice)
                    } label: {
                        Text(advice.advice)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .pressableCard()
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            CheckupStore.deleteEntry(advice, context: context)
                        }
                    }
                } else {
                    Button {
                        editing = .new(.advice)
                    } label: {
                        Label("添加综合建议", systemImage: "plus")
                    }
                }
            } header: {
                Text("综合建议")
            }

            ForEach(CheckupPlan.grouped(values), id: \.category) { group in
                Section {
                    ForEach(group.entries) { value in
                        Button {
                            if let model = entryModels.first(where: { $0.uuid == value.id }) {
                                editing = .existing(model)
                            }
                        } label: {
                            CheckupEntryRow(entry: value)
                                .foregroundStyle(Color.primary)
                                .contentShape(Rectangle())
                        }
                        .pressableCard()
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                if let model = entryModels.first(where: { $0.uuid == value.id }) {
                                    CheckupStore.deleteEntry(model, context: context)
                                }
                            }
                        }
                    }
                } header: {
                    if group.category.isEmpty {
                        Text("其他")
                    } else {
                        Text(group.category)
                    }
                }
            }

            Section {
                Button {
                    editing = .new(.item)
                } label: {
                    Label("添加一项", systemImage: "plus")
                }
            } footer: {
                Text("整理有误的地方点一下就能改;每一项都可以对照原文件核对。")
            }
        }
        .quickLookPreview($previewURL, in: previewFiles)
        #if DEBUG
        .task {
            // --demo-checkup-preview:直接打开原文件,核对 Quick Look。
            if ProcessInfo.processInfo.arguments.contains("--demo-checkup-preview") {
                try? await Task.sleep(for: .seconds(1))
                openFiles(report)
            }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingReport = true
                    } label: {
                        Label("编辑报告信息", systemImage: "pencil")
                    }
                    if !files.isEmpty {
                        Button {
                            openFiles(report)
                        } label: {
                            Label("查看原文件", systemImage: "doc.viewfinder")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除报告", systemImage: "trash")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .existing(let entry):
                CheckupEntryEditView(report: report, entry: entry, kind: entry.kind)
            case .new(let kind):
                CheckupEntryEditView(report: report, entry: nil, kind: kind)
            }
        }
        .sheet(isPresented: $editingReport) {
            CheckupReportEditView(report: report)
        }
        .confirmationDialog("删除这份报告?整理出的条目和原文件会一并删除。",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                CheckupStore.deleteReport(report, context: context)
                dismiss()
            }
        }
    }
}

// MARK: - 一项指标的时间轴

/// 一项指标在历次报告里的变化:数值类画折线(带参考范围那一条带),每次的结果、
/// 结论、报告里针对这一项的建议按时间从近到远列在下面。
struct CheckupMetricView: View {
    let profileID: UUID?
    let key: String

    @Query private var allEntries: [CheckupEntry]
    @State private var editing: CheckupEntry?
    @State private var openReport: UUID?
    @Environment(\.modelContext) private var context

    private var metric: CheckupMetric? {
        CheckupPlan.metrics(from: CheckupStore.entries(ofProfile: profileID, in: allEntries))
            .first { $0.key == key }
    }

    var body: some View {
        Group {
            if let metric {
                content(metric)
            } else {
                ContentUnavailableView("这项指标已经没有记录了", systemImage: "chart.xyaxis.line")
            }
        }
        .navigationTitle(metric?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $openReport) { CheckupReportView(reportID: $0) }
        .sheet(item: $editing) { entry in
            if let report = report(of: entry) {
                CheckupEntryEditView(report: report, entry: entry, kind: entry.kind)
            }
        }
    }

    private func report(of entry: CheckupEntry) -> MemoryItem? {
        let reportID = entry.reportUUID
        return ((try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.uuid == reportID }))) ?? []).first
    }

    private func content(_ metric: CheckupMetric) -> some View {
        List {
            if metric.isNumeric, !metric.points.isEmpty {
                Section {
                    chart(metric)
                } footer: {
                    if let reference = metric.records.last(where: { !$0.referenceRange.isEmpty })?.referenceRange {
                        Text("绿色区域是参考范围 \(reference)")
                    }
                }
            }
            Section {
                ForEach(metric.records.reversed()) { record in
                    Button {
                        editing = allEntries.first { $0.uuid == record.id }
                    } label: {
                        CheckupEntryRow(entry: record, title: Text(record.date, format: checkupDayFormat))
                            .foregroundStyle(Color.primary)
                            .contentShape(Rectangle())
                    }
                    .pressableCard()
                    .contextMenu {
                        Button {
                            openReport = record.reportID
                        } label: {
                            Label("查看这份报告", systemImage: "doc.text")
                        }
                    }
                    .swipeActions {
                        Button {
                            openReport = record.reportID
                        } label: {
                            Label("报告", systemImage: "doc.text")
                        }
                    }
                }
            } header: {
                Text("历次记录")
            }
        }
    }

    /// Swift Charts 是系统框架(同健康页趋势图,不是自绘)。
    private func chart(_ metric: CheckupMetric) -> some View {
        let bounds = metric.referenceBounds
        // 只有一侧的参考范围(<5.2)把带子往另一侧铺出图表外沿,不然只剩一条细缝。
        let values = metric.points.map(\.value) + [bounds.low, bounds.high].compactMap { $0 }
        let span = max((values.max() ?? 0) - (values.min() ?? 0), 0.1)
        let low = bounds.low ?? ((values.min() ?? 0) - span * 0.15)
        let high = bounds.high ?? ((values.max() ?? 0) + span * 0.15)
        return Chart {
            if bounds.low != nil || bounds.high != nil,
               let first = metric.points.first?.date, let last = metric.points.last?.date {
                RectangleMark(
                    xStart: .value("日期", first), xEnd: .value("日期", last),
                    yStart: .value("下限", low), yEnd: .value("上限", high))
                    .foregroundStyle(LodoColor.positive.opacity(0.12))
            }
            ForEach(metric.records.filter { $0.numericValue != nil }) { record in
                LineMark(x: .value("日期", record.date), y: .value("数值", record.numericValue ?? 0))
                    .foregroundStyle(.tint)
                PointMark(x: .value("日期", record.date), y: .value("数值", record.numericValue ?? 0))
                    .foregroundStyle((record.effectiveFlag?.isAbnormal ?? false) ? LodoColor.critical : Color.accentColor)
                    .annotation(position: .top) {
                        Text(record.value)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("\(metric.name) 历次变化"))
    }
}
