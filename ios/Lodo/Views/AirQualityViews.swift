import SwiftUI
import Charts
import LodoCore

// 空气质量(美标 AQI,Open-Meteo):健康页的一组 + 总览的一个模块。取数在 AirQualityStore。

extension AQICategory {
    /// EPA 等级色。只用在色块/圆点/柱子上,**不拿来写字**——「良」那档是纯黄,白底上读不清。
    var color: Color {
        Color(red: Double((colorHex >> 16) & 0xFF) / 255,
              green: Double((colorHex >> 8) & 0xFF) / 255,
              blue: Double(colorHex & 0xFF) / 255)
    }
}

/// 一颗带等级色的圆点 + AQI 数字。
struct AQIBadge: View {
    let aqi: Int
    var font: Font = .system(size: 44, weight: .semibold, design: .rounded)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(AQICategory(aqi: aqi).color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            Text("\(aqi)")
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 健康页

/// 健康页最上面的「空气质量」一组。和健康开关无关(不碰健康数据,Mac 上也能用),
/// 有自己的开关 `airQualityEnabled`,默认关:要定位、会把粗坐标发出去,得用户点一次头。
struct AirQualitySection: View {
    /// 健康页下拉刷新时 +1,这里强制重新请求。
    let refreshToken: Int

    @AppStorage(AppSettings.airQualityEnabledKey) private var enabled = false
    @State private var report: AirQualityReport? = AirQualityStore.cached()
    @State private var failure: AirQualityStore.Failure?
    @State private var loading = false
    @State private var confirmingDisable = false

    var body: some View {
        Section {
            if !enabled {
                disabledRow
            } else if let report {
                reportRows(report)
            } else if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在获取空气质量…").foregroundStyle(.secondary)
                }
            } else if let failure {
                failureRow(failure)
            }
        } header: {
            HStack {
                Text("空气质量")
                Spacer()
                if enabled {
                    Menu {
                        Button("刷新", systemImage: "arrow.clockwise") { Task { await load(force: true) } }
                        Button("关闭空气质量", systemImage: "xmark.circle", role: .destructive) {
                            confirmingDisable = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("空气质量选项")
                }
            }
        } footer: {
            if enabled, let report {
                Text("美标 AQI · 数据来自 Open-Meteo(CAMS 模型),更新于 \(report.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .task(id: refreshToken) { await load(force: refreshToken > 0) }
        .confirmationDialog("关闭空气质量?", isPresented: $confirmingDisable, titleVisibility: .visible) {
            Button("关闭", role: .destructive) {
                enabled = false
                report = nil
                AirQualityStore.disable()
            }
        } message: {
            Text("健康页、总览和小组件都不再显示空气质量,也不再使用位置。")
        }
    }

    private var disabledRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("所在地今天的空气质量", systemImage: "aqi.medium")
                .font(.body.weight(.medium))
            Text("按美国 EPA 标准显示 AQI。会把约 1 公里精度的位置发给 Open-Meteo 查询,不涉及健康数据。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("显示空气质量") {
                enabled = true
                Task { await load(force: true) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func failureRow(_ failure: AirQualityStore.Failure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure == .location ? "无法获取位置" : "空气质量获取失败")
                .font(.body.weight(.medium))
            Text(failure == .location ? "在系统设置里允许 lodo 使用位置后重试。" : "检查网络后下拉刷新重试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("重试") { Task { await load(force: true) } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func reportRows(_ report: AirQualityReport) -> some View {
        let category = report.category
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                AQIBadge(aqi: report.aqi)
                Text(AirQualityStore.title(category))
                    .font(.title3.weight(.semibold))
                Spacer()
                if let dominant = report.dominant {
                    Text("主要污染物 \(dominant.symbol)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(AirQualityStore.advice(category))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let peak = report.peak(after: .now), peak.aqi > report.aqi {
                Text("今天最高 \(peak.aqi),约 \(peak.date.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)

        if !report.hourly.isEmpty {
            AirQualityHourlyChart(hourly: report.hourly)
                .frame(height: 120)
                .padding(.vertical, 4)
        }

        HStack {
            concentration("PM2.5", report.pm2_5)
            concentration("PM10", report.pm10)
            concentration("O₃", report.ozone)
            concentration("NO₂", report.nitrogenDioxide)
        }
    }

    private func concentration(_ symbol: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.body.weight(.medium).monospacedDigit())
            Text(symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHint("微克每立方米")
    }

    private func load(force: Bool) async {
        guard enabled else { return }
        loading = true
        defer { loading = false }
        switch await AirQualityStore.refresh(force: force) {
        case .success(let fresh):
            withAnimation(.lodoAware(.snappy)) { report = fresh }
            failure = nil
        case .failure(let error):
            // 刷新失败时旧数据照样摆着(footer 写着更新时间),没有旧数据才报错。
            if report == nil { failure = error.failure }
        }
    }
}

/// 今天逐小时的 AQI 柱子,按等级上色,「现在」那根下面一条竖线。
struct AirQualityHourlyChart: View {
    let hourly: [AirQualityReport.HourPoint]
    var showsAxis = true

    var body: some View {
        Chart {
            ForEach(hourly, id: \.date) { point in
                BarMark(x: .value("时间", point.date, unit: .hour), y: .value("AQI", point.aqi))
                    .foregroundStyle(AQICategory(aqi: point.aqi).color)
                    .cornerRadius(2)
            }
            RuleMark(x: .value("现在", Date.now, unit: .hour))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis(showsAxis ? .automatic : .hidden)
        .chartYAxis(showsAxis ? .automatic : .hidden)
        .accessibilityLabel("今天逐小时空气质量")
    }
}

// MARK: - 总览

struct OverviewAirQualityWidget: View {
    let size: OverviewWidgetSize
    /// nil = 还没开或没取到。
    let report: AirQualityReport?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .airQuality, action: action) {
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    AQIBadge(aqi: report.aqi, font: .system(size: size == .small ? 36 : 40,
                                                            weight: .semibold, design: .rounded))
                    Text(AirQualityStore.title(report.category))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if size == .large {
                        Text(AirQualityStore.advice(report.category))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !report.hourly.isEmpty {
                            AirQualityHourlyChart(hourly: report.hourly, showsAxis: false)
                                .frame(height: 48)
                        }
                    } else if let dominant = report.dominant {
                        Text(dominant.symbol)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                OverviewEmptyText(text: enabled ? "正在获取空气质量…" : "在健康页开启空气质量后显示")
            }
        }
    }
}
