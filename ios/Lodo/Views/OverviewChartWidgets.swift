import SwiftUI
import Charts
import LodoCore

// 总览页的圆环 / 图表类 widget。圆环是 `Circle().trim` + stroke 的系统形状,
// 图表用 Swift Charts(同健康页)——都不是 Canvas 自绘,别拿它们当引入自绘的先例。
// 数据照旧由 OverviewView 取好传进来,这里只负责画。

/// 一圈进度环。超过 1 的部分再叠一圈(同系统健身记录"超额完成"的画法)。
struct OverviewRing: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat

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
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .animation(.lodoAware(.snappy), value: progress)
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

/// 图例里的一行:色点 + 名称 + 数值。
private struct OverviewRingLegend: View {
    let color: Color
    let title: LocalizedStringKey
    let value: String

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
        }
    }
}

// MARK: - 活动圆环

enum OverviewRingColor {
    /// 系统健身记录的三环配色:活动(红)、锻炼(绿)、站立/步数(青)。
    /// 只用来区分三个指标,不承载状态语义,所以不走 LodoColor。
    static let move = Color(red: 0.98, green: 0.07, blue: 0.31)
    static let exercise = Color(red: 0.45, green: 0.80, blue: 0.10)
    static let steps = Color(red: 0.05, green: 0.75, blue: 0.85)
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
                let rings: [(progress: Double, color: Color)] = [
                    (OverviewCharts.ringProgress(value: energy, goal: ActivityRingGoal.activeEnergy),
                     OverviewRingColor.move),
                    (OverviewCharts.ringProgress(value: exercise, goal: ActivityRingGoal.exerciseMinutes),
                     OverviewRingColor.exercise),
                    (OverviewCharts.ringProgress(value: steps, goal: ActivityRingGoal.steps),
                     OverviewRingColor.steps),
                ]
                if size == .small {
                    OverviewRingStack(rings: rings, diameter: 104)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel(accessibilitySummary(energy, exercise, steps))
                } else {
                    HStack(spacing: 18) {
                        OverviewRingStack(rings: rings, diameter: 104)
                        VStack(spacing: 10) {
                            OverviewRingLegend(color: OverviewRingColor.move, title: "活动",
                                               value: String(localized: "\(format(energy))/\(Int(ActivityRingGoal.activeEnergy)) 千卡"))
                            OverviewRingLegend(color: OverviewRingColor.exercise, title: "锻炼",
                                               value: String(localized: "\(format(exercise))/\(Int(ActivityRingGoal.exerciseMinutes)) 分钟"))
                            OverviewRingLegend(color: OverviewRingColor.steps, title: "步数",
                                               value: "\(format(steps))/\(Int(ActivityRingGoal.steps))")
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "在设置里开启健康分析后显示")
            }
        }
    }

    /// 只认今天的点;最近一个点是昨天时圆环应该是空的,而不是昨天的成绩。
    private func today(_ report: HealthReport, _ kind: HealthMetricKind) -> Double? {
        guard let point = report.series(kind)?.points.last,
              Calendar.current.isDate(point.date, inSameDayAs: now) else { return nil }
        return point.value
    }

    private func format(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? "—"
    }

    private func accessibilitySummary(_ energy: Double?, _ exercise: Double?, _ steps: Double?) -> Text {
        Text("活动 \(format(energy)) 千卡,锻炼 \(format(exercise)) 分钟,步数 \(format(steps))")
    }
}

// MARK: - 今日进度

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
            if size == .small {
                OverviewRingStack(rings: rings, diameter: 104)
                    .overlay { centerLabel(completion) }
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 18) {
                    OverviewRingStack(rings: rings, diameter: 104)
                        .overlay { centerLabel(completion) }
                    VStack(spacing: 10) {
                        OverviewRingLegend(color: accent.accent, title: "任务完成",
                                           value: "\(done)/\(done + remaining)")
                        OverviewRingLegend(color: .secondary, title: "今天已过",
                                           value: "\(Int(dayProgress * 100))%")
                    }
                }
            }
        }
    }

    private func centerLabel(_ completion: Double?) -> some View {
        Text(completion.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            .font(.system(.headline, design: .rounded).weight(.semibold).monospacedDigit())
            .accessibilityLabel(completion == nil ? Text("今天没有任务")
                                                  : Text("今天任务完成 \(done)/\(done + remaining)"))
    }
}

// MARK: - 本周完成

struct OverviewWeeklyDoneWidget: View {
    let size: OverviewWidgetSize
    let days: [OverviewDayCount]
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        let total = days.reduce(0) { $0 + $1.count }
        // 半宽卡片放不下「标题 + 件数 + ›」,小卡把件数挪到图表上方。
        OverviewWidgetCard(kind: .weeklyDone,
                           trailing: size == .large ? String(localized: "\(total) 件") : nil,
                           action: onOpen) {
            if size == .small {
                Text("\(total) 件")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
            }
            Chart(days) { day in
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("完成", day.count))
                    .foregroundStyle(day.isToday ? accent.accent : accent.accent.opacity(0.35))
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis(size == .small ? .hidden : .automatic)
            .chartYScale(domain: 0...max(3, days.map(\.count).max() ?? 0))
            .frame(height: size == .small ? 72 : 120)
            .accessibilityLabel(Text("本周完成 \(total) 件"))
        }
    }
}

// MARK: - 步数趋势

struct OverviewStepsTrendWidget: View {
    let size: OverviewWidgetSize
    /// nil = 健康开关关着。
    let values: [OverviewDayValue]?
    var onOpen: () -> Void

    var body: some View {
        let today = values?.last?.value
        OverviewWidgetCard(kind: .stepsTrend,
                           trailing: today.map { String(Int($0.rounded())) },
                           action: values == nil ? nil : onOpen) {
            if let values {
                if values.allSatisfy({ $0.value == nil }) {
                    OverviewEmptyText(text: "暂无健康数据")
                } else {
                    chart(values)
                }
            } else {
                OverviewEmptyText(text: "在设置里开启健康分析后显示")
            }
        }
    }

    private func chart(_ values: [OverviewDayValue]) -> some View {
        Chart {
            ForEach(values.filter { $0.value != nil }) { day in
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("步数", day.value ?? 0))
                    .foregroundStyle(day.isToday ? OverviewRingColor.steps
                                                 : OverviewRingColor.steps.opacity(0.35))
                    .cornerRadius(4)
            }
            RuleMark(y: .value("目标", ActivityRingGoal.steps))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.secondary)
        }
        .chartXScale(domain: (values.first?.date ?? .now)...(values.last?.date.addingTimeInterval(86400) ?? .now))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis(size == .small ? .hidden : .automatic)
        .frame(height: size == .small ? 96 : 120)
    }
}
