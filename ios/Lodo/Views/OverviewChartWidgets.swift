import SwiftUI
import Charts
import LodoCore

// 总览页的圆环 / 图表类 widget。圆环是 `Circle().trim` + stroke 的系统形状,
// 图表用 Swift Charts(同健康页)——都不是 Canvas 自绘,别拿它们当引入自绘的先例。
// 数据照旧由 OverviewView 取好传进来,这里只负责画。
//
// 几条约定:**缺数据和 0 分开画**(缺的日子不画柱,真是 0 的画一截很矮的灰柱);
// 还没到的日子只留坐标轴标签;圆环超过 100% 时数字照写真实百分比。

/// 一圈进度环。超过 1 的部分再叠一圈(同系统健身记录"超额完成"的画法),
/// 叠的那圈最多一整圈——再多看不出来,真实数字由图例/中心文字说。
struct OverviewRing: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .snappy, value: progress)
    }
}

/// 同心的几圈,由外往里。
struct OverviewRingStack: View {
    let rings: [(progress: Double, color: Color)]
    let diameter: CGFloat

    var body: some View {
        let lineWidth = diameter * (rings.count > 2 ? 0.12 : 0.14)
        let step = lineWidth + 2
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.offset) { index, ring in
                OverviewRing(progress: ring.progress, color: ring.color, lineWidth: lineWidth)
                    .frame(width: diameter - CGFloat(index) * step * 2,
                           height: diameter - CGFloat(index) * step * 2)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 图例里的一行:色点 + 名称 + 数值(+ 灰色的百分比)。
private struct OverviewRingLegend: View {
    let color: Color
    let title: LocalizedStringKey
    let value: String
    var percent: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let percent {
                Text(percent)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 活动圆环

enum OverviewRingColor {
    /// 系统健身记录的三环配色:活动(红)、锻炼(绿)、步数(青)。只用来区分三个
    /// 指标,不承载状态语义,所以不走 LodoColor。原值是给深色底调的,浅色底上
    /// 绿/青只有 2:1 左右,浅色模式换深一档(≥3:1,图形够用)。
    static let move = Color.lodoDynamic(light: 0xD70045, dark: 0xFA114F)
    static let exercise = Color.lodoDynamic(light: 0x3B8500, dark: 0x92E82A)
    static let steps = Color.lodoDynamic(light: 0x00839C, dark: 0x1EEAEF)
}

struct OverviewActivityRingsWidget: View {
    let size: OverviewWidgetSize
    /// nil = 健康开关关着。
    let report: HealthReport?
    let now: Date
    var onOpen: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .activityRings, action: report == nil ? nil : onOpen) {
            if let report {
                let energy = today(report, .activeEnergy)
                let exercise = today(report, .exerciseMinutes)
                let steps = today(report, .steps)
                let progress = (
                    energy: OverviewCharts.ringProgress(value: energy, goal: ActivityRingGoal.activeEnergy),
                    exercise: OverviewCharts.ringProgress(value: exercise, goal: ActivityRingGoal.exerciseMinutes),
                    steps: OverviewCharts.ringProgress(value: steps, goal: ActivityRingGoal.steps))
                let rings: [(progress: Double, color: Color)] = [
                    (progress.energy, OverviewRingColor.move),
                    (progress.exercise, OverviewRingColor.exercise),
                    (progress.steps, OverviewRingColor.steps),
                ]
                let noData = energy == nil && exercise == nil && steps == nil
                Group {
                    if size == .small {
                        VStack(spacing: 8) {
                            OverviewRingStack(rings: rings, diameter: 96)
                                .overlay { if noData { Text(verbatim: "—").font(.headline).foregroundStyle(.secondary) } }
                            if noData {
                                Text("今天还没有数据")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            } else {
                                HStack(spacing: 8) {
                                    smallPercent(energy, progress.energy, OverviewRingColor.move)
                                    smallPercent(exercise, progress.exercise, OverviewRingColor.exercise)
                                    smallPercent(steps, progress.steps, OverviewRingColor.steps)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        HStack(spacing: 18) {
                            OverviewRingStack(rings: rings, diameter: 104)
                            VStack(spacing: 10) {
                                OverviewRingLegend(color: OverviewRingColor.move, title: "活动",
                                                   value: String(localized: "\(format(energy))/\(Int(ActivityRingGoal.activeEnergy)) 千卡",
                                                                 bundle: .appLanguage(), locale: AppSettings.language.locale),
                                                   percent: energy.map { _ in OverviewCharts.percentText(progress.energy) })
                                OverviewRingLegend(color: OverviewRingColor.exercise, title: "锻炼",
                                                   value: String(localized: "\(format(exercise))/\(Int(ActivityRingGoal.exerciseMinutes)) 分钟",
                                                                 bundle: .appLanguage(), locale: AppSettings.language.locale),
                                                   percent: exercise.map { _ in OverviewCharts.percentText(progress.exercise) })
                                OverviewRingLegend(color: OverviewRingColor.steps, title: "步数",
                                                   value: "\(format(steps))/\(Int(ActivityRingGoal.steps).formatted())",
                                                   percent: steps.map { _ in OverviewCharts.percentText(progress.steps) })
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(energy, exercise, steps))
            } else {
                OverviewEmptyText(text: "在设置里开启健康分析后显示")
            }
        }
    }

    /// 小卡圆环下面那排:色点 + 百分比;这一项今天没数据写「—」。
    private func smallPercent(_ value: Double?, _ progress: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value == nil ? "—" : OverviewCharts.percentText(progress))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 只认今天的点;最近一个点是昨天时圆环应该是空的,而不是昨天的成绩。
    private func today(_ report: HealthReport, _ kind: HealthMetricKind) -> Double? {
        guard let point = report.series(kind)?.points.last,
              Calendar.current.isDate(point.date, inSameDayAs: now) else { return nil }
        return point.value
    }

    private func format(_ value: Double?) -> String {
        value.map { Int($0.rounded()).formatted() } ?? "—"
    }

    private func accessibilitySummary(_ energy: Double?, _ exercise: Double?, _ steps: Double?) -> Text {
        func part(_ value: Double?, _ text: Text) -> Text {
            value == nil ? Text("暂无数据") : text
        }
        return Text("活动") + Text(" ")
            + part(energy, Text("\(format(energy))/\(Int(ActivityRingGoal.activeEnergy)) 千卡"))
            + Text(",") + Text("锻炼") + Text(" ")
            + part(exercise, Text("\(format(exercise))/\(Int(ActivityRingGoal.exerciseMinutes)) 分钟"))
            + Text(",") + Text("步数") + Text(" ")
            + part(steps, Text(verbatim: "\(format(steps))/\(Int(ActivityRingGoal.steps).formatted())"))
    }
}

// MARK: - 今日进度

/// 外圈:今天原定的任务完成了几成(以前积压的不算,见 `OverviewCharts.todayPlan`);
/// 内圈:今天过去了几成——两圈对着看,就知道进度跟不跟得上时间。
struct OverviewTaskProgressWidget: View {
    let size: OverviewWidgetSize
    let done: Int
    let remaining: Int
    let now: Date
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        OverviewWidgetCard(kind: .taskProgress, action: onOpen) {
            let completion = OverviewCharts.taskCompletion(done: done, remaining: remaining)
            let dayProgress = OverviewTime.dayProgress(at: now)
            let rings: [(progress: Double, color: Color)] = [
                (completion ?? 0, accent.accent),
                (dayProgress, Color.secondary),
            ]
            Group {
                if size == .small {
                    VStack(spacing: 6) {
                        OverviewRingStack(rings: rings, diameter: 96)
                            .overlay { centerLabel(completion) }
                        Text("今天已过 \(Int(dayProgress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 18) {
                        OverviewRingStack(rings: rings, diameter: 104)
                            .overlay { centerLabel(completion) }
                        VStack(spacing: 10) {
                            OverviewRingLegend(color: accent.accent, title: "今天的任务",
                                               value: "\(done)/\(done + remaining)")
                            OverviewRingLegend(color: .secondary, title: "今天已过",
                                               value: "\(Int(dayProgress * 100))%")
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(completion == nil
                                ? Text("今天没有任务") + Text(",") + Text("今天已过 \(Int(dayProgress * 100))%")
                                : Text("今天任务完成 \(done)/\(done + remaining)") + Text(",")
                                    + Text("今天已过 \(Int(dayProgress * 100))%"))
        }
    }

    private func centerLabel(_ completion: Double?) -> some View {
        Text(completion.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            .font(.system(.headline, design: .rounded).weight(.semibold).monospacedDigit())
    }
}

// MARK: - 本周完成

/// 小卡:本周每天的柱子(还没到的日子不画,已过去但一件没做的画一截矮灰柱)+ 和上周
/// 同期比。大卡:最近 4 周的热力格子,不会每到周一就清零。
struct OverviewWeeklyDoneWidget: View {
    let size: OverviewWidgetSize
    /// 最近 4 周(`OverviewCharts.recentWeeks(weeks: 4)`),最后 7 个是本周。
    let days: [OverviewDayCount]
    let comparison: (thisWeek: Int, lastWeek: Int)
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    private var thisWeek: [OverviewDayCount] { days.filter { $0.weekOffset == 0 } }

    var body: some View {
        let weekTotal = thisWeek.reduce(0) { $0 + $1.count }
        OverviewWidgetCard(kind: .weeklyDone,
                           trailing: size == .large
                               ? String(localized: "\(weekTotal) 件", bundle: .appLanguage(), locale: AppSettings.language.locale)
                               : nil,
                           action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if size == .small {
                    Text("\(weekTotal) 件")
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    weekBars
                        .frame(height: 64)
                } else {
                    heatmap
                }
                comparisonText
            }
        }
    }

    private var weekdaySymbols: [String] {
        var calendar = Calendar.current
        calendar.locale = AppSettings.language.locale
        let symbols = calendar.shortStandaloneWeekdaySymbols  // 周日起头
        return Array(symbols.dropFirst()) + [symbols[0]]
    }

    private var weekBars: some View {
        let maxCount = max(3, thisWeek.map(\.count).max() ?? 0)
        return Chart(thisWeek) { day in
            if !day.isFuture {
                BarMark(x: .value("日期", day.date, unit: .day),
                        // 0 也画一截矮柱,和"还没到的日子"(不画)分开。
                        y: .value("完成", day.count == 0 ? Double(maxCount) * 0.04 : Double(day.count)))
                    .foregroundStyle(day.count == 0 ? Color.secondary.opacity(0.3)
                                     : day.isToday ? accent.accent : accent.accent.opacity(0.5))
                    .cornerRadius(3)
                    .accessibilityLabel(Text(day.date, format: .dateTime.weekday(.wide)))
                    .accessibilityValue(Text("\(day.count) 件"))
            }
        }
        .chartXScale(domain: (thisWeek.first?.date ?? .now)...(thisWeek.last.map {
            Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date } ?? .now))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(AppSettings.language.locale), centered: true)
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...Double(maxCount))
    }

    /// 4×7 的格子。系统 Grid + 圆角矩形摆出来(Swift Charts 的分类轴会把行标签
    /// 挤到格子上方),没有 Canvas。
    private var heatmap: some View {
        let symbols = weekdaySymbols
        let maxCount = max(1, days.map(\.count).max() ?? 0)
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            ForEach(-3...0, id: \.self) { offset in
                GridRow {
                    Text(weekLabel(offset))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                    ForEach(days.filter { $0.weekOffset == offset }) { day in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(cellColor(day, maxCount: maxCount))
                            .overlay {
                                if day.isToday {
                                    RoundedRectangle(cornerRadius: 5).strokeBorder(accent.accent, lineWidth: 1.5)
                                }
                            }
                            .overlay {
                                if day.count > 0 {
                                    Text("\(day.count)")
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(Double(day.count) / Double(maxCount) > 0.5
                                                         ? accent.onFill : .primary)
                                }
                            }
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(day.date, format: .dateTime.month().day().weekday()))
                            .accessibilityValue(day.isFuture ? Text("还没到") : Text("\(day.count) 件"))
                    }
                }
            }
        }
    }

    private func cellColor(_ day: OverviewDayCount, maxCount: Int) -> Color {
        if day.isFuture { return Color.secondary.opacity(0.05) }
        if day.count == 0 { return Color.secondary.opacity(0.14) }
        return accent.fill.opacity(0.3 + 0.7 * Double(day.count) / Double(maxCount))
    }

    private func weekLabel(_ offset: Int) -> String {
        let locale = AppSettings.language.locale
        switch offset {
        case 0: return String(localized: "本周", bundle: .appLanguage(), locale: locale)
        case -1: return String(localized: "上周", bundle: .appLanguage(), locale: locale)
        default: return String(localized: "\(-offset) 周前", bundle: .appLanguage(), locale: locale)
        }
    }

    @ViewBuilder
    private var comparisonText: some View {
        let delta = comparison.thisWeek - comparison.lastWeek
        let total = days.reduce(0) { $0 + $1.count }
        Group {
            if size == .large {
                if delta == 0 {
                    Text("近 4 周 \(total) 件 · 和上周同期持平")
                } else {
                    Text("近 4 周 \(total) 件 · 比上周同期 \(signed(delta))")
                }
            } else if delta == 0 {
                Text("和上周同期持平")
            } else {
                Text("比上周同期 \(signed(delta))")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}

// MARK: - 步数趋势

struct OverviewStepsTrendWidget: View {
    let size: OverviewWidgetSize
    /// nil = 健康开关关着。
    let values: [OverviewDayValue]?
    var onOpen: () -> Void

    var body: some View {
        let today = values?.last?.value
        let todayText = today.map { Int($0.rounded()).formatted() }
            ?? String(localized: "今日暂无", bundle: .appLanguage(), locale: AppSettings.language.locale)
        // 半宽卡片放不下「标题 + 步数 + ›」,小卡把今天的步数挪到图表上方(同本周完成)。
        OverviewWidgetCard(kind: .stepsTrend,
                           trailing: values == nil || size == .small ? nil : todayText,
                           action: values == nil ? nil : onOpen) {
            if let values {
                if values.allSatisfy({ $0.value == nil }) {
                    OverviewEmptyText(text: "暂无健康数据")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if size == .small {
                            Text(verbatim: todayText)
                                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        }
                        chart(values)
                        if size == .large { summary(values) }
                    }
                }
            } else {
                OverviewEmptyText(text: "在设置里开启健康分析后显示")
            }
        }
    }

    private func chart(_ values: [OverviewDayValue]) -> some View {
        let peak = max(ActivityRingGoal.steps * 1.15, values.compactMap(\.value).max() ?? 0)
        return Chart {
            ForEach(values.filter { $0.value != nil }) { day in
                let value = day.value ?? 0
                BarMark(x: .value("日期", day.date, unit: .day),
                        // 真走了 0 步(戴着表)画一截矮灰柱;没数据的日子不画。
                        y: .value("步数", value <= 0 ? peak * 0.03 : value))
                    .foregroundStyle(value <= 0 ? Color.secondary.opacity(0.3)
                                     : day.isToday ? OverviewRingColor.steps
                                     : OverviewRingColor.steps.opacity(0.55))
                    .cornerRadius(4)
                    .accessibilityLabel(Text(day.date, format: .dateTime.weekday(.wide)))
                    .accessibilityValue(Text(verbatim: Int(value).formatted()))
            }
            RuleMark(y: .value("目标", ActivityRingGoal.steps))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing, spacing: 1) {
                    Text(verbatim: Int(ActivityRingGoal.steps).formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
        .chartXScale(domain: (values.first?.date ?? .now)...(values.last.map {
            Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date } ?? .now))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(AppSettings.language.locale), centered: true)
            }
        }
        .chartYAxis(size == .small ? .hidden : .automatic)
        .chartYScale(domain: 0...peak)
        .frame(height: size == .small ? 72 : 120)
    }

    private func summary(_ values: [OverviewDayValue]) -> some View {
        let known = values.compactMap(\.value)
        let average = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
        return Text("\(values.count) 天里 \(known.count) 天有数据 · 日均 \(Int(average.rounded()).formatted()) 步")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
