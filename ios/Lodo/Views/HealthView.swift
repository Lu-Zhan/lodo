import SwiftUI
import SwiftData
import Charts
import LodoCore

/// "健康" 页:总览/待办/记忆/AI 之外的第五个平级页面。把系统健康库里的数据
/// (`HealthKitBridge`)汇总成日级指标 + 趋势图,再结合记忆库里打了「健康」
/// 标签的条目让 AI 给一段分析。
///
/// 隐私上有两道门:总开关默认关(`AppSettings.healthEnabled`),关着时这一页
/// 一个网络请求都不发;开着时也只把**汇总统计**(日均/最近一天/环比)发给 AI,
/// 逐条原始样本不出 `HealthKitBridge`。
struct HealthView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.healthEnabledKey) private var healthEnabled = false
    @AppStorage(AppSettings.healthRangeDaysKey) private var rangeDays = 14
    @AppStorage(AppSettings.cycleTrackingKey) private var cyclePreferenceRaw = ""
    @AppStorage(AppSettings.medicationVisibleKey) private var medicationVisible = true
    @AppStorage(AppSettings.biologicalSexKey) private var biologicalSexRaw = ""
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query private var checkupEntries: [CheckupEntry]
    /// 右上角「+」→「记体重」的默认值要用(同「今天」那组)。
    @Query(sort: [SortDescriptor(\WeightRecord.date, order: .reverse)])
    private var weightRecords: [WeightRecord]
    @Environment(\.sidebarChrome) private var sidebarChrome
    /// 右上角「+」菜单打开的表单。
    @State private var addSheet: HealthAddSheet?

    @State private var report: HealthReport = .empty
    @State private var analysis: HealthAnalysis?
    @State private var loadingReport = false
    @State private var loadingAnalysis = false
    /// 最近一次分析请求失败了(和"没配 AI"分开:配了 AI 的人不该看到"去配置")。
    @State private var analysisFailed = false
    /// AI 分析默认收起,点开才显示(也才发请求);不持久化,每次进来都是收起的。
    @State private var analysisExpanded = false
    /// 下拉刷新时 +1,空气质量那一组跟着强制重新请求。
    @State private var airRefreshToken = 0
    /// 刚上传整理完的体检报告,直接 push 进它的详情。
    @State private var openReport: UUID?
    /// 接受了共享邀请的家人档案,push 进去(见 `SharedTripSync.openHealthProfileRequest`)。
    @State private var openProfile: CheckupProfileTarget?
    /// 右上角「+」里的「上传体检报告」。
    @State private var importingCheckup = false
    /// 截图参数直接推进去的二级页(--demo-weight-scroll / --demo-weight-report-live / --demo-medication-page)。
    @State private var openWeightPage = false
    @State private var openMedicationPage = false
    @State private var openCyclePage = false
    #if DEBUG
    /// --demo-health 的临时放行。用 @State 而不是把 healthEnabled 写成 true:
    /// 那是 @AppStorage,会落进 UserDefaults 影响之后不带参数的启动。
    @State private var demoOverride = false
    /// --demo-checkup-profile / --demo-checkup-metric 直接打开的页面。
    @State private var demoCheckupProfile = false
    @State private var demoCheckupMetric: String?
    #endif

    /// 是否该展示数据区(而不是"未开启"空态)。
    private var showsData: Bool {
        #if DEBUG
        return healthEnabled || demoOverride
        #else
        return healthEnabled
        #endif
    }

    private static let analysisDayKey = "healthAnalysisDay"
    private static let analysisTextKey = "healthAnalysisText"
    private static let analysisSuggestionsKey = "healthAnalysisSuggestions"
    /// 缓存那份分析时用的体检摘要:报告新增/改过之后当天也要重新分析。
    private static let analysisCheckupKey = "healthAnalysisCheckup"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 记忆库里打了「健康」标签的条目(用药、饮食记录这些)。体检报告不在这里:
    /// 它们在「体检档案」那一组,喂给 AI 的也是结构化的摘要(`CheckupStore.selfPromptSummary`)。
    private var healthMemories: [MemoryItem] {
        memoryItems.filter { $0.isHealth && !$0.isCheckup }
    }

    /// 今天的活动能量(Apple Watch 记的那一圈),健康库里今天还没有就是 nil。
    private var todayActiveEnergy: Double? {
        guard let last = report.series(.activeEnergy)?.points.last,
              Calendar.current.isDateInToday(last.date) else { return nil }
        return last.value
    }

    /// 「经期」那一组显不显示(设置里选的,自动 = 健康 App 里是女性)。
    private var showsCycle: Bool {
        CyclePlan.isEnabled(CyclePlan.Preference(rawValue: cyclePreferenceRaw) ?? .auto,
                            sex: CyclePlan.Sex(rawValue: biologicalSexRaw) ?? .unknown)
    }

    /// 今天的步数:健康库序列最后一点就是今天才算(旧数据不冒充今天)。
    private var todaySteps: Double? {
        guard showsData, let last = report.series(.steps)?.points.last,
              Calendar.current.isDateInToday(last.date) else { return nil }
        return last.value
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button { addSheet = .weight } label: { Label("记体重", systemImage: "scalemass") }
        Button { addSheet = .food } label: { Label("记饮食", systemImage: "fork.knife") }
        if medicationVisible {
            Button { addSheet = .medication } label: { Label("添加药品", systemImage: "pills") }
        }
        Divider()
        Button { addSheet = .note } label: { Label("记一笔健康资料", systemImage: "square.and.pencil") }
        Button { importingCheckup = true } label: { Label("上传体检报告", systemImage: "doc.text.viewfinder") }
    }

    private var healthWeights: [HealthDailyPoint] {
        showsData ? (report.series(.bodyMass)?.points ?? []) : []
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            // 2026-10 重新设计(方案与 codex 一起定):今天 → 天气 → 健康管理 → 经期 → 健康数据 →
            // 健康资料 → AI 分析。首页最多七组,体重趋势/饮食流水/用药目录/指标/档案都推进二级页。
            List {
                // 今天要记的、要吃的:不依赖健康开关(手记就能用,Mac 上也有)。
                HealthTodaySection(healthWeights: healthWeights, todaySteps: todaySteps,
                                   healthEnabled: healthEnabled, medicationVisible: medicationVisible)
                // 空气质量和健康开关、健康库都无关(Mac 上也能看),自己有开关。
                AirQualitySection(refreshToken: airRefreshToken)
                HealthManageSection(
                    healthWeights: healthWeights,
                    healthSummary: showsData && !report.isEmpty ? report.promptSummary() : nil,
                    todayActiveEnergy: showsData ? todayActiveEnergy : nil,
                    healthEnabled: healthEnabled, medicationVisible: medicationVisible,
                    showsCycle: showsCycle, refreshToken: airRefreshToken)
                healthDataSection
                librarySection
                // AI 健康分析放在整页最下面(用户要求);仍然默认收起,点开才显示、才去要。
                if HealthKitBridge.isAvailable, showsData, !report.isEmpty {
                    analysisSection
                }
            }
            #if DEBUG
            .task {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--demo-health-records-scroll") {
                    try? await Task.sleep(for: .seconds(1.5))
                    proxy.scrollTo(HealthTodaySection.anchor, anchor: .top)
                    return
                }
                // 体重和饮食现在在二级页:推进去(那一页自己负责滚到「今日饮食」/打开上传)。
                if args.contains("--demo-weight-scroll") || args.contains("--demo-weight-report-live") {
                    openWeightPage = true
                }
                if args.contains("--demo-medication-page") { openMedicationPage = true }
                if args.contains("--demo-cycle-page") { openCyclePage = true }
                // 滚到下半截(健康管理 → 健康资料 → AI 分析),核对首页后面几组。
                if args.contains("--demo-health-scroll-lower") {
                    try? await Task.sleep(for: .seconds(1.5))
                    proxy.scrollTo(Self.lowerAnchor, anchor: .top)
                }
            }
            #endif
            }
            .navigationDestination(item: $openReport) { CheckupReportView(reportID: $0) }
            .navigationDestination(isPresented: $openWeightPage) {
                WeightManagementView(
                    healthWeights: healthWeights,
                    healthSummary: showsData && !report.isEmpty ? report.promptSummary() : nil,
                    todayActiveEnergy: showsData ? todayActiveEnergy : nil)
            }
            .navigationDestination(isPresented: $openMedicationPage) {
                MedicationManagementView(healthEnabled: healthEnabled)
            }
            .navigationDestination(isPresented: $openCyclePage) {
                CycleManagementView(healthEnabled: healthEnabled)
            }
            .sheet(isPresented: $importingCheckup) {
                CheckupImportView(initialProfile: nil) { openReport = $0.uuid }
            }
            .navigationDestination(item: $openProfile) { CheckupProfileView(profileID: $0.id) }
            .onChange(of: SharedTripSync.shared.openHealthProfileRequest) { _, _ in consumeProfileRequest() }
            .onAppear { consumeProfileRequest() }
            #if DEBUG
            .navigationDestination(isPresented: $demoCheckupProfile) { CheckupProfileView(profileID: nil) }
            .navigationDestination(item: $demoCheckupMetric) { CheckupMetricView(profileID: nil, key: $0) }
            #endif
            .pageTitle("健康")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // 手动记录收在右上角「+」(下拉在刷新数据,不改成新建)。都存进 lodo 自己的库,
            // 不依赖健康开关、不写健康库。
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false) {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            addMenuItems
                        } label: {
                            Label("添加记录", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(item: $addSheet) { sheet in
                switch sheet {
                case .weight:
                    WeightRecordEditView(record: nil, defaults: WeightPlan.merge(
                        records: weightRecords.map(\.entry), health: healthWeights))
                case .food: FoodRecordComposeView()
                case .medication: MedicationEditView(medication: nil)
                case .note: MemoryComposeView(presetTags: [MemoryItem.healthTagName])
                }
            }
            .sidebarToolbarButton()
            .askBar(focus: .health)
            // 开关、回看天数一变就重新读(换 id 时 SwiftUI 会先取消还在跑的那一次——
            // 关掉开关时正等着 HealthKit 的那次读完也不会再去发 AI 请求)。
            .task(id: "\(healthEnabled)-\(rangeDays)") {
                await reload()
            }
            // 经期:读健康 App 的经期 + 重排提醒,挂在页面根上(不挂在会被懒加载回收的标题上),
            // 同一组配置读过就不再读,见 `CycleHealthPeriods`。
            // (读取本身跑在协调器自己的任务上,这里只是按配置发起,页面被推走也不会读到一半丢掉。)
            .task(id: "\(showsCycle)-\(healthEnabled)-\(airRefreshToken)") {
                CycleHealthPeriods.shared.refresh(enabled: showsCycle, healthEnabled: healthEnabled,
                                                  token: airRefreshToken, context: context)
            }
            // 手表完成的用药提醒补记、健康 App 服药记录导入:挂在页面上而不是用药那一组上,
            // 组被隐藏了也照样跑(隐藏只管显示)。
            .task(id: "\(healthEnabled)-\(airRefreshToken)") {
                MedicationStore.backfillDosesFromHistory(context: context)
                await MedicationStore.importHealthDoses(context: context)
            }
            #if DEBUG
            .task {
                applyDemoArgumentsIfNeeded()
                applyCheckupDemoIfNeeded()
                HealthRecordsDemo.seedIfRequested(context: context)
                HealthRecordsDemo.seedCycleIfRequested(context: context)
            }
            #endif
            .refreshable {
                airRefreshToken += 1
                await reload(force: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    // MARK: - 健康数据 / 健康资料(首页各一组入口,内容在二级页)

    /// 「健康数据」:一行,按状态写清楚是什么情况,点进去是指标与趋势或完整说明。
    private var healthDataSection: some View {
        Section("健康数据") {
            healthDataLink
            #if DEBUG
                .id(Self.lowerAnchor)
            #endif
        }
    }

    private var healthDataLink: some View {
        Group {
            NavigationLink {
                HealthDataView(report: report, loading: loadingReport, showsData: showsData) {
                    await reload(force: true)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.text.square")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        healthDataTitle.font(.body.weight(.medium))
                        healthDataDetail
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if showsData, loadingReport, report.isEmpty {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var healthDataTitle: Text {
        if !HealthKitBridge.isAvailable { return Text("健康数据") }
        if !showsData { return Text("健康分析未开启") }
        if loadingReport && report.isEmpty { return Text("正在读取健康数据…") }
        if report.isEmpty { return Text("暂无健康数据") }
        return Text("指标与趋势")
    }

    private var healthDataDetail: Text {
        if !HealthKitBridge.isAvailable { return Text("步数、睡眠、心率只在 iPhone 上有") }
        if !showsData { return Text("了解并开启") }
        if report.isEmpty { return Text("查看说明") }
        return Text("最近 \(rangeDays) 天 · \(report.series.count) 项指标")
    }

    /// 「健康资料」:体检档案、健康记录、身体档案三个入口(上传体检报告在体检档案里和右上角「+」)。
    private var librarySection: some View {
        Section {
            NavigationLink {
                CheckupLibraryView(memoryItems: memoryItems, openReport: $openReport)
            } label: {
                libraryRow(title: "体检档案", systemImage: "doc.text.magnifyingglass",
                           detail: checkupCount == 0 ? Text("还没有体检报告") : Text("\(checkupCount) 份报告"))
            }
            NavigationLink {
                HealthMemoryListView(items: healthMemories)
            } label: {
                libraryRow(title: "健康记录", systemImage: "heart.text.square",
                           detail: healthMemories.isEmpty ? Text("病历、过敏这类资料") : Text("\(healthMemories.count) 条记录"))
            }
            NavigationLink {
                BodyArchiveView(
                    reports: bodyReports, weightRecords: weightRecords, healthWeights: healthWeights,
                    healthSummary: showsData && !report.isEmpty ? report.promptSummary() : nil,
                    todayActiveEnergy: showsData ? todayActiveEnergy : nil)
            } label: {
                libraryRow(title: "身体档案", systemImage: "figure.stand",
                           detail: bodyReports.isEmpty ? Text("体重、体脂率等体重秤报告")
                                                       : Text("\(bodyReports.count) 份档案"))
            }
        } header: {
            Text("健康资料")
        }
    }

    private var checkupCount: Int { memoryItems.filter(\.isCheckup).count }
    /// 身体档案 = 上传过的体重秤报告(记忆条目,打「体重秤报告」标签)。
    private var bodyReports: [MemoryItem] { memoryItems.filter(\.isWeightReport) }

    #if DEBUG
    /// --demo-health-scroll-lower 滚到这里(「健康数据」那一行)。
    private static let lowerAnchor = "healthLowerAnchor"
    #endif

    private func libraryRow(title: LocalizedStringKey, systemImage: String, detail: Text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - AI 分析

    @ViewBuilder
    private var analysisSection: some View {
        Section {
            Button {
                withAnimation(.lodoAware(.snappy)) { analysisExpanded.toggle() }
                if analysisExpanded, analysis == nil, !loadingAnalysis {
                    Task { await loadAnalysis() }
                }
            } label: {
                HStack {
                    Label("AI 健康分析", systemImage: "sparkles")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(analysisExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(analysisExpanded ? Text("已展开") : Text("已收起"))
            if analysisExpanded {
                analysisContent
            }
        }
    }

    @ViewBuilder
    private var analysisContent: some View {
        if loadingAnalysis {
            HStack {
                ProgressView().controlSize(.small)
                Text("正在分析…").foregroundStyle(.secondary)
            }
        } else if let analysis {
            Text(analysis.analysis)
                .font(.body)
            ForEach(analysis.suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "checkmark.circle")
                    .font(.body)
            }
            if analysisFailed {
                retryRow("这次没能刷新分析,上面是之前的结果。")
            }
        } else if analysisFailed {
            retryRow("这次没能生成分析,可能是网络或 AI 服务暂时出错。")
        } else if !DeepSeekClient.isConfigured {
            Text("配置 AI 服务后,这里会给出针对这几天数据的分析和建议。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func retryRow(_ message: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("重试") {
                Task { await loadAnalysis(force: true) }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)
        }
    }

    /// 页面可能是这时才第一次建出来的(那一下不走 onChange),onAppear 也收一次。
    private func consumeProfileRequest() {
        guard let uuid = SharedTripSync.shared.openHealthProfileRequest else { return }
        SharedTripSync.shared.openHealthProfileRequest = nil
        openProfile = CheckupProfileTarget(id: uuid)
    }

    // MARK: - 加载

    private func reload(force: Bool = false) async {
        guard healthEnabled else {
            report = .empty
            analysis = nil
            analysisFailed = false
            return
        }
        loadingReport = true
        // 顺带读一下健康 App 里的性别:设置里「经期记录」选「自动」时靠它决定开不开。
        HealthKitBridge.refreshBiologicalSex()
        let fresh = await HealthKitBridge.report(days: rangeDays)
        loadingReport = false
        // 等 HealthKit 的这段时间里开关可能被关掉、回看天数可能变了:过期的结果不要。
        guard !Task.isCancelled, healthEnabled else { return }
        report = fresh
        // 收起时不发请求;换了天数/下拉刷新时把旧结果清掉,下次点开重新要。
        guard analysisExpanded else {
            analysis = nil
            analysisFailed = false
            return
        }
        await loadAnalysis(force: force)
    }

    /// 按天缓存(和 OverviewView.loadSuggestion 同一套写法):只在成功时写缓存,
    /// 离线/请求失败不会把当天"钉死"成空。没数据就不请求。
    /// 缓存键带上回看天数和应用语言:换了 30 天,标题写着「最近 30 天」,分析不能还是 14 天那份。
    private func loadAnalysis(force: Bool = false) async {
        guard healthEnabled, DeepSeekClient.isConfigured, !report.isEmpty else {
            analysis = nil
            analysisFailed = false
            return
        }
        let stamp = "\(Self.dayFormatter.string(from: Date()))|\(rangeDays)|\(AppSettings.language.rawValue)"
        let defaults = UserDefaults.standard
        // 体检只给本人的(家人的档案不参与健康分析)。报告改过之后当天也重新分析。
        let checkup = CheckupStore.selfPromptSummary(items: memoryItems, entries: checkupEntries)
        if !force, defaults.string(forKey: Self.analysisDayKey) == stamp,
           defaults.string(forKey: Self.analysisCheckupKey) == (checkup ?? ""),
           let cached = defaults.string(forKey: Self.analysisTextKey) {
            analysis = HealthAnalysis(
                analysis: cached,
                suggestions: defaults.stringArray(forKey: Self.analysisSuggestionsKey) ?? [])
            analysisFailed = false
            return
        }
        var contextParts: [String] = []
        if let checkup { contextParts.append("体检报告:\n\(checkup)") }
        if !healthMemories.isEmpty {
            contextParts.append(healthMemories.prefix(10)
                .map { "「\($0.title)」\($0.summary)" }.joined(separator: "、"))
        }
        let memoryContext = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n")
        loadingAnalysis = true
        defer { loadingAnalysis = false }
        let result = try? await DeepSeekClient.analyzeHealth(
            summary: report.promptSummary(), memoryContext: memoryContext)
        // 请求期间开关被关、页面换了参数:结果作废,也不写缓存。
        guard !Task.isCancelled, healthEnabled else { return }
        guard let result else {
            analysisFailed = true
            return
        }
        analysisFailed = false
        defaults.set(stamp, forKey: Self.analysisDayKey)
        defaults.set(result.analysis, forKey: Self.analysisTextKey)
        defaults.set(result.suggestions, forKey: Self.analysisSuggestionsKey)
        defaults.set(checkup ?? "", forKey: Self.analysisCheckupKey)
        analysis = result
    }

    #if DEBUG
    /// 体检档案的截图参数:--demo-checkup 塞样板(本人两份 + 妈妈一份,不走网络),
    /// 配 --demo-checkup-profile / --demo-checkup-report / --demo-checkup-metric <指标名>
    /// 直接打开对应页面。
    private func applyCheckupDemoIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        // --demo-checkup-normalize-dump:按本机真实数据算一次「重新匹配检查项」的方案
        // 打到控制台(会真发 AI 请求),**不落库**,真机上核对匹配结果用。
        if arguments.contains("--demo-checkup-normalize-dump") {
            Task {
                do {
                    let plan = try await CheckupStore.normalizationPlan(profileID: nil, context: context)
                    for group in plan.groups {
                        print("[checkup-normalize] merge \(group.variants) -> \(group.canonical) (\(group.recordCount))")
                    }
                    for entry in plan.removals {
                        print("[checkup-normalize] remove \(entry.name) \(CheckupPlan.dayString(entry.date)) \(entry.displayValue)")
                    }
                    print("[checkup-normalize] updates=\(plan.updates.count) removals=\(plan.removals.count)")
                } catch {
                    print("[checkup-normalize] failed: \(error)")
                }
            }
        }
        guard arguments.contains("--demo-checkup") else { return }
        CheckupStore.seedDemo(context: context)
        // 真发一次 AI:拿样板 PDF 走完整的识别 → 整理 → 落库,整理完打开那份报告。
        if arguments.contains("--demo-checkup-import-live"),
           let pdf = CheckupStore.demoPDFURL() {
            Task {
                do {
                    let item = try await CheckupStore.importReport(
                        files: [pdf], images: [], profileID: nil, context: context)
                    openReport = item.uuid
                } catch {
                    print("[checkup-demo] import failed: \(error)")
                }
            }
            return
        }
        // --demo-checkup-shared:把样板家人标成"已共享"(只改本地标记,不发 iCloud 请求)。
        let family = (try? context.fetch(FetchDescriptor<HealthProfile>()))?.first
        if arguments.contains("--demo-checkup-shared"), let family {
            family.shareRoleRaw = SharedTripRole.owner.rawValue
            try? context.save()
        }
        if arguments.contains("--demo-checkup-family"), let family {
            openProfile = CheckupProfileTarget(id: family.uuid)
        } else if arguments.contains("--demo-checkup-profile") {
            demoCheckupProfile = true
        } else if arguments.contains("--demo-checkup-report") {
            let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
            openReport = CheckupStore.reports(of: nil, in: items).first?.uuid
        } else if let index = arguments.firstIndex(of: "--demo-checkup-metric"),
                  index + 1 < arguments.count {
            demoCheckupMetric = CheckupPlan.metricKey(arguments[index + 1])
        }
    }

    /// 截图验证用:模拟器里没有真实健康数据,用启动参数摆一份样本序列和假分析,
    /// 和 --demo-overview-ai / --demo-reschedule 同一个惯例。
    private func applyDemoArgumentsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--demo-health") else { return }
        demoOverride = true
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func series(_ kind: HealthMetricKind, _ values: [Double]) -> HealthSeries {
            let points = values.enumerated().compactMap { index, value -> HealthDailyPoint? in
                guard let date = calendar.date(
                    byAdding: .day, value: index - values.count + 1, to: today) else { return nil }
                return HealthDailyPoint(date: date, value: value)
            }
            return HealthSeries(kind: kind, points: points)
        }
        report = HealthReport(series: [
            series(.steps, [6200, 7100, 5400, 8300, 9100, 7600, 8800,
                            9400, 10200, 8700, 11300, 9800, 10500, 11200]),
            series(.sleepHours, [6.4, 7.1, 6.8, 5.9, 7.3, 7.6, 6.9,
                                 7.2, 6.6, 7.4, 7.0, 6.3, 7.5, 7.1]),
            series(.activeEnergy, [380, 420, 310, 520, 610, 450, 480,
                                   530, 590, 470, 640, 560, 600, 420]),
            series(.restingHeartRate, [62, 63, 64, 66, 63, 61, 62,
                                       61, 60, 61, 59, 60, 61, 59]),
        ], rangeDays: 14)
        analysis = HealthAnalysis(
            analysis: "这两周步数稳步上升,静息心率跟着降了 3 次/分,是有氧在起作用;睡眠时长忽高忽低,周中偏短。",
            suggestions: ["把入睡时间固定在 23:30 前", "周三、周五各补一次 30 分钟快走", "睡前一小时不看手机"])
        loadingReport = false
        loadingAnalysis = false
    }
    #endif
}

/// 健康页右上角「+」打开的几张表单。
private enum HealthAddSheet: String, Identifiable {
    case weight, food, medication, note
    var id: String { rawValue }
}
