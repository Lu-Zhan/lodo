import SwiftUI
import Charts
import LodoCore

/// 资产页「统计」那一档:趋势(总资产折线,过去 6 个月按填写日期、未来 6 个月按每月结余估计)
/// + 各项组成(资产 / 负债 / 收入)。只读,算好的数据从 `AssetsView` 传进来;放在 List 里,
/// body 直接给出几个 Section。图用 Swift Charts(系统框架,同健康页),不是自绘。
struct AssetStatsSections: View {
    let trend: AssetTrend
    let monthlyNet: Double
    let assets: FinancePlan.Composition
    let liabilities: FinancePlan.Composition
    let income: FinancePlan.Composition
    let currency: String
    let excludedCount: Int
    let now: Date

    @Environment(\.lodoAccent) private var lodoAccent

    var body: some View {
        trendSection
        if !assets.slices.isEmpty {
            compositionSection("资产组成", assets)
        }
        // 没有负债就不显示这一组。
        if !liabilities.slices.isEmpty {
            compositionSection("负债组成", liabilities)
        }
        if !income.slices.isEmpty {
            compositionSection("收入组成(每月)", income)
        }
    }

    // MARK: - 趋势

    private var trendSection: some View {
        Section {
            if trend.isEmpty {
                Text("记下资产的金额后,这里会画出总资产的变化。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("总资产").font(.subheadline).foregroundStyle(.secondary)
                        Text(AssetFormat.currency(trend.history.last?.total ?? 0, code: currency))
                            .font(.title2.bold().monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let end = trend.projection.last {
                            Text("6 个月后约 \(AssetFormat.currency(end.total, code: currency))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    trendChart
                    legend
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("趋势")
        } footer: {
            trendFooter
        }
    }

    private var trendChart: some View {
        Chart {
            ForEach(Array(trend.history.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("日期", point.date), y: .value("总资产", point.total),
                         series: .value("类型", "记录"))
                    .foregroundStyle(lodoAccent.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.stepEnd)
            }
            // 填写过金额的那几天打点;起点(6 个月前)和"现在"是推出来的,不打点。
            ForEach(Array(filledPoints.enumerated()), id: \.offset) { _, point in
                PointMark(x: .value("日期", point.date), y: .value("总资产", point.total))
                    .foregroundStyle(lodoAccent.accent)
                    .symbolSize(30)
            }
            ForEach(Array(trend.projection.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("日期", point.date), y: .value("总资产", point.total),
                         series: .value("类型", "估计"))
                    .foregroundStyle(lodoAccent.accent.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            }
            RuleMark(x: .value("今天", now))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated)
                    .locale(AppSettings.language.locale))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount.formatted(.number.notation(.compactName)
                            .locale(AppSettings.language.locale)))
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("总资产趋势")
    }

    /// 起点和"现在"之间、真正填写过金额的那些点。
    private var filledPoints: [AssetTrend.Point] {
        let history = trend.history
        guard history.count > 2 else { return [] }
        let start = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now
        return Array(history.dropLast()).filter { $0.date > start }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(dashed: false, title: "记录")
            legendItem(dashed: true, title: monthlyNet >= 0
                ? "估计:每月 +\(AssetFormat.currency(monthlyNet, code: currency))"
                : "估计:每月 −\(AssetFormat.currency(-monthlyNet, code: currency))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func legendItem(dashed: Bool, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .stroke(lodoAccent.accent.opacity(dashed ? 0.55 : 1),
                        style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 1)
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var trendFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if trend.needsUpdate {
                // 6 个月都没更新:图上是上一次记录的结果,提醒更新一下。
                Label {
                    if let last = trend.lastUpdate {
                        Text("最近 6 个月没有更新过资产,图上是 \(last.formatted(.dateTime.year().month().day().locale(AppSettings.language.locale))) 记录的结果。可以更新一下资产了。")
                    } else {
                        Text("最近 6 个月没有更新过资产,可以更新一下资产了。")
                    }
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .foregroundStyle(lodoAccent.accent)
            }
            if !trend.isEmpty {
                Text("实线是填写金额的记录;虚线按每月结余(收入 − 固定支出和月供 − 月估计消费)往后估 6 个月,不定期的收入不算。")
            }
            if !trend.missingCurrencies.isEmpty {
                Text("以下币种暂时换不到汇率,没有计入:\(trend.missingCurrencies.joined(separator: "、"))")
            }
            if excludedCount > 0 {
                Text("有 \(excludedCount) 项资产设成了不计入总资产,不在统计里。")
            }
        }
    }

    // MARK: - 组成

    private static let palette: [Color] = [.blue, .teal, .orange, .purple, .pink, .green, .yellow, .brown]

    /// 块太多时把最小的几块合成「其余」,饼图上 8 种颜色已经是能分得清的上限。
    private func merged(_ slices: [FinancePlan.Slice]) -> [FinancePlan.Slice] {
        let limit = Self.palette.count
        guard slices.count > limit else { return slices }
        let rest = slices.dropFirst(limit - 1).reduce(0) { $0 + $1.amount }
        let restName = String(localized: "其余", bundle: .appLanguage(), locale: AppSettings.language.locale)
        return Array(slices.prefix(limit - 1)) + [FinancePlan.Slice(name: restName, amount: rest)]
    }

    private func compositionSection(_ title: LocalizedStringKey,
                                    _ composition: FinancePlan.Composition) -> some View {
        let slices = merged(composition.slices)
        let total = composition.total
        return Section {
            ZStack {
                Chart(Array(slices.enumerated()), id: \.offset) { index, slice in
                    SectorMark(angle: .value("金额", slice.amount),
                               innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(Self.palette[index % Self.palette.count])
                }
                .chartLegend(.hidden)
                VStack(spacing: 2) {
                    Text("合计").font(.footnote).foregroundStyle(.secondary)
                    Text(AssetFormat.currency(total, code: currency))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: 110)
            }
            .frame(height: 190)
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Self.palette[index % Self.palette.count])
                        .frame(width: 10, height: 10)
                    Text(LocalizedStringKey(slice.name))
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(AssetFormat.currency(slice.amount, code: currency))
                        .font(.subheadline.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(percent(slice.amount, of: total))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(title)
        } footer: {
            if !composition.missingCurrencies.isEmpty {
                Text("以下币种暂时换不到汇率,没有计入:\(composition.missingCurrencies.joined(separator: "、"))")
            }
        }
    }

    private func percent(_ part: Double, of total: Double) -> String {
        guard total > 0 else { return "" }
        return (part / total).formatted(.percent.precision(.fractionLength(0))
            .locale(AppSettings.language.locale))
    }
}
