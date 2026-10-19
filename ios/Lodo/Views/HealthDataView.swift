import SwiftUI
import Charts
import LodoCore

/// 健康页「健康数据」二级页:健康库的最近 N 天指标 + 趋势图,以及没有健康库(Mac)/
/// 没开健康分析 / 没数据时的完整说明。数据本身仍由 `HealthView` 读(`report`),这一页
/// 不另起 HealthKit 请求;改回看天数写的是同一个设置,`HealthView` 那边按它重读。
struct HealthDataView: View {
    let report: HealthReport
    let loading: Bool
    /// 开了健康分析(或截图参数放行)。
    let showsData: Bool
    /// 重新请求权限后重读一次。
    let reload: () async -> Void

    @AppStorage(AppSettings.healthEnabledKey) private var healthEnabled = false
    @AppStorage(AppSettings.healthRangeDaysKey) private var rangeDays = 14
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var chartKind: HealthMetricKind?

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    /// 当前画折线的指标:选过且这段时间有数据的那条,否则第一条有数据的。
    private var shownKind: HealthMetricKind? {
        if let chartKind, report.series(chartKind) != nil { return chartKind }
        return report.series.first?.kind
    }

    var body: some View {
        List {
            if !HealthKitBridge.isAvailable {
                unavailableSection
            } else if !showsData {
                disabledSection
            } else if loading && report.isEmpty {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取健康数据…").foregroundStyle(.secondary)
                    }
                }
            } else if report.isEmpty {
                noDataSection
            } else {
                Section {
                    Picker("回看天数", selection: $rangeDays) {
                        Text("7 天").tag(7)
                        Text("14 天").tag(14)
                        Text("30 天").tag(30)
                    }
                    .segmentedPickerStyle()
                    .standaloneSwitchLayout()
                }
                metricsSection
                chartSection
            }
        }
        .pageTitle("健康数据")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - 空态

    /// 这台设备上没有健康库(Mac 一律如此)。体重、用药这些手记和健康资料照常可用。
    private var unavailableSection: some View {
        Section {
            ContentUnavailableView {
                Label("这台设备没有健康数据", systemImage: "heart.text.square")
            } description: {
                Text("步数、睡眠、心率等数据只在 iPhone 和 Apple Watch 上有,请在 iPhone 上的 lodo 里查看趋势和 AI 分析。体检报告、病历这类健康资料仍然可以在这里记录,也能问 AI。")
            }
            .emptyStateFill()
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
                        // 置开关就会触发健康页按开关重读的 task,这里不再手动 reload 一遍。
                        healthEnabled = true
                    }
                }
                .glassProminentButton()
            }
            .emptyStateFill()
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
                        await reload()
                    }
                }
                .glassProminentButton()
            }
            .emptyStateFill()
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        Section {
            ForEach(report.series, id: \.kind) { item in
                metricRow(item.kind)
            }
        } header: {
            Text("最近 \(rangeDays) 天")
        } footer: {
            Text("点一项在下面看它的趋势。")
        }
    }

    /// 点一项 = 下面的趋势图换成它。原来是 onTapGesture,换成 Button:旁白和键盘也能点。
    private func metricRow(_ kind: HealthMetricKind) -> some View {
        let unit = LocalizedStrings.text(kind.unitKey, language: language)
        return Button {
            withAnimation(.lodoAware(.snappy)) { chartKind = kind }
        } label: {
            HStack {
                Label(LocalizedStrings.text(kind.titleKey, language: language),
                      systemImage: kind.systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let latest = report.latest(kind) {
                        Text("\(kind.format(latest)) \(unit)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.primary)
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
        }
        .pressableCard()
        .accessibilityAddTraits(shownKind == kind ? .isSelected : [])
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

    /// Swift Charts 是系统框架,和"UI 只用系统控件、不自绘"的约定不冲突。
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
}
