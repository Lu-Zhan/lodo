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
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query private var checkupEntries: [CheckupEntry]

    @State private var report: HealthReport = .empty
    @State private var analysis: HealthAnalysis?
    @State private var loadingReport = false
    @State private var loadingAnalysis = false
    @State private var chartKind: HealthMetricKind?
    /// 下拉刷新时 +1,空气质量那一组跟着强制重新请求。
    @State private var airRefreshToken = 0
    /// 刚上传整理完的体检报告,直接 push 进它的详情。
    @State private var openReport: UUID?
    /// 接受了共享邀请的家人档案,push 进去(见 `SharedTripSync.openHealthProfileRequest`)。
    @State private var openProfile: CheckupProfileTarget?
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

    /// 当前画折线的指标:默认第一条有数据的序列。
    private var shownKind: HealthMetricKind? {
        chartKind ?? report.series.first?.kind
    }

    var body: some View {
        NavigationStack {
            List {
                // 空气质量排最上面:和健康开关、健康库都无关(Mac 上也能看),自己有开关。
                AirQualitySection(refreshToken: airRefreshToken)
                if !HealthKitBridge.isAvailable {
                    unavailableSection
                } else if !showsData {
                    disabledSection
                } else if loadingReport && report.isEmpty {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在读取健康数据…").foregroundStyle(.secondary)
                        }
                    }
                } else if report.isEmpty {
                    noDataSection
                } else {
                    // AI 分析排在最前:它是这一页真正要看的结论,指标格子和
                    // 折线图是支撑它的原始数据,读的顺序该是"先看结论,再往下
                    // 核对数据",不是反过来滑到底才看到一句话。
                    analysisSection
                    metricsSection
                    chartSection
                }
                CheckupSection(memoryItems: memoryItems, openReport: $openReport)
                memoriesSection
            }
            .navigationDestination(item: $openReport) { CheckupReportView(reportID: $0) }
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
            .sidebarToolbarButton()
            .askBar(focus: .health)
            .task {
                await reload()
                #if DEBUG
                applyDemoArgumentsIfNeeded()
                applyCheckupDemoIfNeeded()
                #endif
            }
            .refreshable {
                airRefreshToken += 1
                await reload(force: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    // MARK: - 空态

    /// 这台设备上没有健康库(Mac 一律如此)。读数这一半用不了,但下面「健康资料」
    /// 那一组(体检报告、病历等记忆条目)照常可以记、可以问 AI。
    private var unavailableSection: some View {
        Section {
            ContentUnavailableView {
                Label("这台设备没有健康数据", systemImage: "heart.text.square")
            } description: {
                Text("步数、睡眠、心率等数据只在 iPhone 和 Apple Watch 上有,请在 iPhone 上的 lodo 里查看趋势和 AI 分析。体检报告、病历这类健康资料仍然可以在这里记录,也能问 AI。")
            }
        }
    }

    private var disabledSection: some View {
        Section {
            ContentUnavailableView {
                Label("健康分析未开启", systemImage: "heart.text.square")
            } description: {
                Text("开启后 lodo 会读取步数、睡眠、心率等数据,在本机汇总成趋势;只有汇总统计会发给 AI,原始记录不会离开这台设备。")
            } actions: {
                Button("开启健康分析") {
                    Task {
                        await HealthKitBridge.requestAuthorization()
                        healthEnabled = true
                        await reload(force: true)
                    }
                }
                .glassProminentButton()
            }
        }
    }

    /// HealthKit 出于隐私不告诉 app 读权限被拒了,所以"没授权"和"确实没数据"
    /// 在这里是同一种空态,文案要把两种可能都说到。
    private var noDataSection: some View {
        Section {
            ContentUnavailableView {
                Label("暂无健康数据", systemImage: "heart.text.square")
            } description: {
                Text("可能是还没授权,或者这段时间没有记录。可以到系统「设置 → 隐私与安全性 → 健康」里检查 lodo 的权限。")
            } actions: {
                Button("重新请求权限") {
                    Task {
                        await HealthKitBridge.requestAuthorization()
                        await reload(force: true)
                    }
                }
                .glassProminentButton()
            }
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        Section("最近 \(rangeDays) 天") {
            ForEach(report.series, id: \.kind) { item in
                metricRow(item.kind)
            }
        }
    }

    private func metricRow(_ kind: HealthMetricKind) -> some View {
        let unit = LocalizedStrings.text(kind.unitKey, language: language)
        return HStack {
            Label(LocalizedStrings.text(kind.titleKey, language: language),
                  systemImage: kind.systemImage)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let latest = report.latest(kind) {
                    Text("\(kind.format(latest)) \(unit)")
                        .font(.body.monospacedDigit())
                }
                if let average = report.average(kind) {
                    Text("日均 \(kind.format(average)) \(unit)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            trendBadge(kind)
        }
        .contentShape(Rectangle())
        .onTapGesture { chartKind = kind }
    }

    /// 趋势箭头。心率/体重没有"越高越好"的单一方向,只给中性灰。
    @ViewBuilder
    private func trendBadge(_ kind: HealthMetricKind) -> some View {
        if let trend = report.trend(kind), abs(trend) >= 0.01 {
            let rising = trend > 0
            Text(Image(systemName: rising ? "arrow.up.right" : "arrow.down.right"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(kind.higherIsBetter == rising ? LodoColor.positive : Color.secondary)
                // 用 Text 而不是 String 传旁白标签:String 那个重载是 verbatim 的,
                // 走不到字符串目录。
                .accessibilityLabel(rising ? Text("上升") : Text("下降"))
        }
    }

    // MARK: - 趋势图

    /// Swift Charts 是系统框架,和"UI 只用系统控件、不自绘"的约定不冲突——
    /// 这里**不**开 ContactGraphView 那种 Canvas 自绘的第二个先例。
    @ViewBuilder
    private var chartSection: some View {
        if let kind = shownKind, let series = report.series(kind) {
            Section("趋势") {
                Picker("指标", selection: Binding(
                    get: { kind },
                    set: { chartKind = $0 }
                )) {
                    ForEach(report.series, id: \.kind) { item in
                        Text(LocalizedStrings.text(item.kind.titleKey, language: language))
                            .tag(item.kind)
                    }
                }
                .pickerStyle(.menu)
                Chart(series.points, id: \.date) { point in
                    LineMark(x: .value("日期", point.date, unit: .day),
                             y: .value("数值", point.value))
                    PointMark(x: .value("日期", point.date, unit: .day),
                              y: .value("数值", point.value))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
                .padding(.vertical, 4)
                .accessibilityLabel(
                    LocalizedStrings.text(kind.titleKey, language: language)
                        + LocalizedStrings.text(.ios_core_health_trend_chart_suffix, language: language))
            }
        }
    }

    // MARK: - AI 分析

    @ViewBuilder
    private var analysisSection: some View {
        Section("AI 分析") {
            if loadingAnalysis {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在分析…").foregroundStyle(.secondary)
                }
            } else if let analysis {
                Label(analysis.analysis, systemImage: "sparkles")
                    .font(.body)
                ForEach(analysis.suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "checkmark.circle")
                        .font(.body)
                }
            } else {
                Text("配置 AI 服务后,这里会给出针对这几天数据的分析和建议。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 健康记录(记忆库)

    private var memoriesSection: some View {
        Section {
            if healthMemories.isEmpty {
                Text("还没有健康记录。体检报告、用药、饮食这些跟底下那条「问问 AI」说一句就能记下来,AI 分析时会一并参考。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(healthMemories) { item in
                    NavigationLink {
                        MemoryDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            // 分开写而不是三元:三元的两支都是 String,会挑到
                            // Text 的 verbatim 重载,"未命名"就进不了字符串目录。
                            Group {
                                if item.title.isEmpty {
                                    Text("未命名")
                                } else {
                                    Text(item.title)
                                }
                            }
                            .font(.body.weight(.medium))
                            if !item.summary.isEmpty {
                                Text(item.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("健康记录")
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
            return
        }
        loadingReport = true
        report = await HealthKitBridge.report(days: rangeDays)
        loadingReport = false
        await loadAnalysis(force: force)
    }

    /// 按天缓存(和 OverviewView.loadSuggestion 同一套写法):只在成功时写缓存,
    /// 离线/请求失败不会把当天"钉死"成空。没数据就不请求。
    private func loadAnalysis(force: Bool = false) async {
        guard DeepSeekClient.isConfigured, !report.isEmpty else {
            analysis = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        // 体检只给本人的(家人的档案不参与健康分析)。报告改过之后当天也重新分析。
        let checkup = CheckupStore.selfPromptSummary(items: memoryItems, entries: checkupEntries)
        if !force, defaults.string(forKey: Self.analysisDayKey) == stamp,
           defaults.string(forKey: Self.analysisCheckupKey) == (checkup ?? ""),
           let cached = defaults.string(forKey: Self.analysisTextKey) {
            analysis = HealthAnalysis(
                analysis: cached,
                suggestions: defaults.stringArray(forKey: Self.analysisSuggestionsKey) ?? [])
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
        guard let result = try? await DeepSeekClient.analyzeHealth(
            summary: report.promptSummary(), memoryContext: memoryContext) else { return }
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
