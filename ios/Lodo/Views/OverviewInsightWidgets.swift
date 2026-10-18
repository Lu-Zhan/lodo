import SwiftUI
import Charts
import LodoCore

// 总览页后来加的四张模块:积压提醒、旅行中、睡眠与恢复、例行状态。
// 同 OverviewChartWidgets:数据由 OverviewView 取好传进来,这里只画;
// 图用 Swift Charts / 系统形状,没有 Canvas。

// MARK: - 积压提醒

/// 原定时间已过、还没完成的任务按拖了多久分档。纠缠式提醒的"欠账"一眼看清:
/// 小卡是件数 + 最久拖了几天 + 一条分段条,大卡是四档横条 + 拖得最久的那件。
struct OverviewBacklogWidget: View {
    let size: OverviewWidgetSize
    let backlog: OverviewBacklog
    /// 拖得最久的那件。
    let oldest: TaskItem?
    var onOpen: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .backlog,
                           trailing: size == .large && backlog.total > 0 ? "\(backlog.total)" : nil,
                           action: onOpen) {
            if backlog.total == 0 {
                Label("没有积压的提醒", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(LodoColor.positive)
            } else if size == .small {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(backlog.total) 件")
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    if let days = backlog.oldestDays {
                        (days == 0 ? Text("都是今天的") : Text("最久拖了 \(days) 天"))
                            .font(.footnote)
                            .foregroundStyle(days >= 4 ? LodoColor.critical : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    segmentBar
                        .frame(height: 10)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    bars
                    if let oldest, let days = backlog.oldestDays, days > 0 {
                        Text("拖得最久:「\(oldest.title)」\(days) 天")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// 拖得越久颜色越深(同一个警示色,只改浓淡——别再多造一套状态色)。
    private func color(_ bucket: OverviewBacklog.Bucket) -> Color {
        switch bucket {
        case .today: return LodoColor.critical.opacity(0.35)
        case .days1to3: return LodoColor.critical.opacity(0.55)
        case .days4to7: return LodoColor.critical.opacity(0.78)
        case .older: return LodoColor.critical
        }
    }

    private func title(_ bucket: OverviewBacklog.Bucket) -> String {
        let locale = AppSettings.language.locale
        switch bucket {
        case .today: return String(localized: "今天", bundle: .appLanguage(), locale: locale)
        case .days1to3: return String(localized: "1–3 天", bundle: .appLanguage(), locale: locale)
        case .days4to7: return String(localized: "4–7 天", bundle: .appLanguage(), locale: locale)
        case .older: return String(localized: "更早", bundle: .appLanguage(), locale: locale)
        }
    }

    private var segmentBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(OverviewBacklog.Bucket.allCases, id: \.self) { bucket in
                    let count = backlog.count(bucket)
                    if count > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(bucket))
                            .frame(width: max(4, (geo.size.width - 6) * CGFloat(count) / CGFloat(backlog.total)))
                    }
                }
            }
        }
    }

    /// 四档横条。条数固定四条、只比长短,用 Rectangle 按比例摆比 Swift Charts 的
    /// 分类轴更干净(分类轴会给每档画网格线、标签挤在条上)。
    private var bars: some View {
        let maxCount = max(1, backlog.counts.max() ?? 1)
        return VStack(spacing: 6) {
            ForEach(OverviewBacklog.Bucket.allCases, id: \.self) { bucket in
                let count = backlog.count(bucket)
                HStack(spacing: 8) {
                    Text(title(bucket))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(count == 0 ? Color.secondary.opacity(0.12) : color(bucket))
                            .frame(width: count == 0 ? 4 : max(6, geo.size.width * CGFloat(count) / CGFloat(maxCount)))
                    }
                    .frame(height: 12)
                    Text("\(count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(count == 0 ? .tertiary : .secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title(bucket)) + Text(verbatim: " ") + Text("\(count) 件"))
            }
        }
    }

    private var accessibilitySummary: Text {
        Text("积压 \(backlog.total) 件") + Text(",")
            + Text("最久拖了 \(backlog.oldestDays ?? 0) 天")
    }
}

// MARK: - 旅行中

struct OverviewTripWidget: View {
    let size: OverviewWidgetSize
    let trip: TravelTrip?
    let status: OverviewTripStatus?
    let now: Date
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        OverviewWidgetCard(kind: .trip, action: trip == nil ? nil : onOpen) {
            if let trip, let status {
                VStack(alignment: .leading, spacing: 8) {
                    Text(trip.displayEmoji + " " + trip.title)
                        .font(.body.weight(.medium))
                        .lineLimit(size == .small ? 2 : 1)
                    switch status.phase {
                    case .ongoing(let day, let of):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(day)/\(of) 天")
                                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                            ProgressView(value: Double(day), total: Double(max(of, 1)))
                                .accessibilityLabel(Text("第 \(day)/\(of) 天"))
                        }
                    case .upcoming(let days):
                        (days <= 1 ? Text("明天出发") : Text("还有 \(days) 天出发"))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    if size == .large, !status.today.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(status.today.prefix(3)) { entry in entryLine(entry) }
                        }
                    } else if let next = status.next {
                        entryLine(next)
                    }
                    if size == .large, let tonight = status.tonight {
                        Label {
                            Text("今晚住 \(tonight.title)").lineLimit(1)
                        } icon: {
                            Image(systemName: "bed.double.fill").foregroundStyle(accent.accent)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                OverviewEmptyText(text: "近期没有旅行")
            }
        }
    }

    private func entryLine(_ entry: TravelEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbolName)
                .font(.footnote)
                .foregroundStyle(accent.accent)
                .frame(width: 18)
            Text(entry.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let start = entry.start {
                Text(start > now ? LocalizedContent.relativeTimeLabel(to: start, from: now)
                                 : LocalizedContent.time(start))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(start < now ? .tertiary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }
}

// MARK: - 睡眠与恢复

/// 健康类模块原来全是活动量;这张补上恢复:最近 7 天睡眠柱子 + 静息心率折线。
/// 缺的日子留空不补 0;不编"恢复分数"之类没有定义的综合指标。
struct OverviewRecoveryWidget: View {
    let size: OverviewWidgetSize
    /// nil = 健康开关关着。
    let report: HealthReport?
    let now: Date
    var onOpen: () -> Void

    private static let sleepColor = Color.lodoDynamic(light: 0x4F46E5, dark: 0x8B88FF)
    private static let heartColor = Color.lodoDynamic(light: 0xC9252D, dark: 0xFF6961)

    var body: some View {
        OverviewWidgetCard(kind: .recovery, action: report == nil ? nil : onOpen) {
            if let report {
                let sleep = days(report, .sleepHours)
                let heart = days(report, .restingHeartRate)
                if sleep.allSatisfy({ $0.value == nil }) && heart.allSatisfy({ $0.value == nil }) {
                    OverviewEmptyText(text: "暂无睡眠和心率数据")
                } else if size == .small {
                    VStack(alignment: .leading, spacing: 4) {
                        latestLine(sleep, kind: .sleepHours)
                        sleepChart(sleep).frame(height: 56)
                        if let rhr = report.latest(.restingHeartRate) {
                            (Text("静息心率") + Text(verbatim: " \(HealthMetricKind.restingHeartRate.format(rhr)) "
                                + LocalizedStrings.text(HealthMetricKind.restingHeartRate.unitKey,
                                                        language: AppSettings.language)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                latestLine(sleep, kind: .sleepHours)
                                sleepChart(sleep).frame(height: 80)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                latestLine(heart, kind: .restingHeartRate)
                                heartChart(heart).frame(height: 80)
                            }
                        }
                        if let hrv = report.average(.hrv) {
                            Text("心率变异性 7 天平均 \(HealthMetricKind.hrv.format(hrv)) 毫秒")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "在设置里开启健康分析后显示")
            }
        }
    }

    private func days(_ report: HealthReport, _ kind: HealthMetricKind) -> [OverviewDayValue] {
        OverviewCharts.recentDays(points: report.series(kind)?.points.map { ($0.date, $0.value) } ?? [],
                                  now: now)
    }

    /// 「睡眠 7.2 小时」,最近一个有数据的日子;不是今天的写上是哪天。
    private func latestLine(_ values: [OverviewDayValue], kind: HealthMetricKind) -> some View {
        let latest = values.last { $0.value != nil }
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.footnote)
                .foregroundStyle(kind == .sleepHours ? Self.sleepColor : Self.heartColor)
            if let latest, let value = latest.value {
                Text(verbatim: kind.format(value))
                    .font(.system(.headline, design: .rounded).monospacedDigit())
                Text(LocalizedStrings.text(kind.unitKey, language: AppSettings.language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !latest.isToday {
                    Text(latest.date, format: .dateTime.weekday(.abbreviated))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(verbatim: "—").font(.headline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func sleepChart(_ values: [OverviewDayValue]) -> some View {
        Chart(values.filter { $0.value != nil }) { day in
            BarMark(x: .value("日期", day.date, unit: .day), y: .value("小时", day.value ?? 0))
                .foregroundStyle(day.isToday ? Self.sleepColor : Self.sleepColor.opacity(0.55))
                .cornerRadius(3)
        }
        .chartXScale(domain: domain(values))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(AppSettings.language.locale), centered: true)
            }
        }
        .chartYAxis(.hidden)
    }

    private func heartChart(_ values: [OverviewDayValue]) -> some View {
        let known = values.compactMap(\.value)
        let low = (known.min() ?? 50) - 4
        let high = (known.max() ?? 70) + 4
        return Chart(values.filter { $0.value != nil }) { day in
            LineMark(x: .value("日期", day.date, unit: .day), y: .value("次/分", day.value ?? 0))
                .foregroundStyle(Self.heartColor)
                .interpolationMethod(.monotone)
            PointMark(x: .value("日期", day.date, unit: .day), y: .value("次/分", day.value ?? 0))
                .foregroundStyle(Self.heartColor)
                .symbolSize(day.isToday ? 40 : 16)
        }
        .chartXScale(domain: domain(values))
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(AppSettings.language.locale), centered: true)
            }
        }
        .chartYAxis(.hidden)
    }

    private func domain(_ values: [OverviewDayValue]) -> ClosedRange<Date> {
        let first = values.first?.date ?? now
        let last = values.last.map { Calendar.current.date(byAdding: .day, value: 1, to: $0.date) ?? $0.date } ?? now
        return first...max(first, last)
    }
}

// MARK: - 例行状态

/// 定时任务最近 7 天每天跑得怎么样 + 下一次什么时候。「今日例行」只给成功的结果,
/// 失败了在那里是看不出来的,这张补上。没有记录的日子画空圈,不说成"漏跑"
/// (运行记录里没有计划时间槽,判断不了)。
struct OverviewRoutineStatusWidget: View {
    let size: OverviewWidgetSize
    let status: OverviewRoutineStatus
    let now: Date

    var body: some View {
        OverviewWidgetCard(kind: .routineStatus,
                           trailing: size == .large && status.failures > 0
                               ? String(localized: "失败 \(status.failures) 次", bundle: .appLanguage(),
                                        locale: AppSettings.language.locale)
                               : nil) {
            if status.rows.isEmpty {
                OverviewEmptyText(text: "还没有定时任务")
            } else if size == .small {
                VStack(alignment: .leading, spacing: 6) {
                    if let next = status.nextRun,
                       let row = status.rows.first(where: { $0.id == next.id }) {
                        Text(LocalizedContent.relativeTimeLabel(to: next.date, from: now))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(row.name)
                            .font(.subheadline)
                            .lineLimit(1)
                    } else {
                        Text("没有启用的定时任务")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Label {
                        status.failures == 0 ? Text("近 7 天都成功了") : Text("近 7 天失败 \(status.failures) 次")
                    } icon: {
                        Image(systemName: status.failures == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(status.failures == 0 ? LodoColor.positive : LodoColor.critical)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(status.rows.prefix(5)) { row in
                        HStack(spacing: 8) {
                            Text(row.name)
                                .font(.subheadline)
                                .foregroundStyle(row.enabled ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            HStack(spacing: 4) {
                                ForEach(Array(row.days.enumerated()), id: \.offset) { _, state in dot(state) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(rowSummary(row))
                            Text(row.nextRun.map { LocalizedContent.time($0) }
                                 ?? String(localized: "已停用", bundle: .appLanguage(), locale: AppSettings.language.locale))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .trailing)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func dot(_ state: OverviewRoutineStatus.DayState) -> some View {
        Group {
            switch state {
            case .success: Circle().fill(LodoColor.positive)
            case .failed: Circle().fill(LodoColor.critical)
            case .none: Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
            }
        }
        .frame(width: 8, height: 8)
    }

    private func rowSummary(_ row: OverviewRoutineStatus.Row) -> Text {
        let success = row.days.filter { $0 == .success }.count
        let failed = row.days.filter { $0 == .failed }.count
        return Text("近 7 天成功 \(success) 天,失败 \(failed) 天")
    }
}
