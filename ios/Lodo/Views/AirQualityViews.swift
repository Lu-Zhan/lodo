import SwiftUI
import Charts
import UserNotifications
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
    @State private var showsReminders = false
    @AppStorage(AppSettings.airQualityReminderTimesKey) private var reminderTimes = ""

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
                        Button("提醒设置…", systemImage: "bell") { showsReminders = true }
                        Button("关闭空气质量", systemImage: "xmark.circle", role: .destructive) {
                            confirmingDisable = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("空气质量选项")
                }
            }
            // sheet/确认框/task 挂在标题行上:挂在 Section 上会分摊到每一行(task 跑好几遍,sheet 弹不出来)。
            .sheet(isPresented: $showsReminders) { AirQualityReminderSettingsView() }
            .confirmationDialog("关闭空气质量?", isPresented: $confirmingDisable, titleVisibility: .visible) {
                Button("关闭", role: .destructive) {
                    enabled = false
                    report = nil
                    AirQualityStore.disable()
                }
            } message: {
                Text("健康页、总览和小组件都不再显示空气质量,也不再使用位置。")
            }
            .task(id: refreshToken) {
                await load(force: refreshToken > 0)
                #if DEBUG
                // 截图验证:直接打开提醒设置;--demo-air-pending 把已排的提醒打到控制台。
                let args = ProcessInfo.processInfo.arguments
                if refreshToken == 0, args.contains("--demo-air-reminders") { showsReminders = true }
                if args.contains("--demo-air-pending") {
                    try? await Task.sleep(for: .seconds(2))
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    for slot in AirQualityNotifier.contents(for: report) {
                        print("[air-pending] plan \(slot.date.formatted(date: .abbreviated, time: .shortened)) | \(slot.title) | \(slot.body)")
                    }
                    print("[air-pending] auth=\(settings.authorizationStatus.rawValue) times=\(AirQualityNotifier.times) hourly=\(report?.hourly.count ?? -1)")
                    for request in await UNUserNotificationCenter.current().pendingNotificationRequests()
                    where request.identifier.hasPrefix(AirQualityNotifier.prefix) {
                        let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
                        print("[air-pending] \(request.identifier) in \(Int(trigger?.timeInterval ?? 0))s | \(request.content.title) | \(request.content.body)")
                    }
                }
                #endif
            }
        } footer: {
            if enabled, let report {
                Text("美标 AQI · 数据来自 Open-Meteo(CAMS 模型),更新于 \(report.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
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

        if !report.todayHourly(now: .now).isEmpty {
            AirQualityHourlyChart(hourly: report.todayHourly(now: .now))
                .frame(height: 120)
                .padding(.vertical, 4)
        }

        Button { showsReminders = true } label: {
            HStack {
                Label("提醒", systemImage: "bell")
                Spacer()
                let times = AirQualityReminderPlan.parseTimes(reminderTimes)
                Text(times.isEmpty ? String(localized: "未开启", bundle: .appLanguage(),
                                            locale: AppSettings.language.locale)
                     : times.joined(separator: "、"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .pressable()
        .foregroundStyle(.primary)

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
                        if !report.todayHourly(now: .now).isEmpty {
                            AirQualityHourlyChart(hourly: report.todayHourly(now: .now), showsAxis: false)
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

// MARK: - 提醒设置

/// 空气质量提醒:几个时间点 + 「只在空气不好时提醒」。改动当场按缓存的预报重排通知。
struct AirQualityReminderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.lodoAccent) private var lodoAccent
    @AppStorage(AppSettings.airQualityReminderTimesKey) private var timesRaw = ""
    @AppStorage(AppSettings.airQualityReminderOnlyBadKey) private var onlyBad = false

    private var times: [String] { AirQualityReminderPlan.parseTimes(timesRaw) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("空气质量提醒", isOn: Binding(
                        get: { !times.isEmpty },
                        set: { on in
                            timesRaw = on ? "07:30" : ""
                            if on { requestNotificationPermission() }
                            apply()
                        }))
                } footer: {
                    Text("按 Open-Meteo 的逐小时预报提前排好:每条提醒写着那个时间起三小时内预计最高的 AQI,附上简短建议。打开 lodo 或后台刷新时会用最新预报重排。")
                }
                if !times.isEmpty {
                    Section("提醒时间") {
                        ForEach(times, id: \.self) { time in
                            DatePicker(LocalizedStringKey("提醒时间"), selection: binding(for: time),
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onDelete { offsets in
                            var next = times
                            next.remove(atOffsets: offsets)
                            timesRaw = AirQualityReminderPlan.encode(next)
                            apply()
                        }
                        if times.count < AirQualityReminderPlan.maxTimes {
                            Button("添加时间", systemImage: "plus") {
                                let candidates = ["07:30", "12:00", "17:30", "21:00", "09:00", "15:00"]
                                let next = candidates.first { !times.contains($0) } ?? "08:00"
                                timesRaw = AirQualityReminderPlan.encode(times + [next])
                                apply()
                            }
                        }
                    }
                    Section {
                        Toggle("只在空气不好时提醒", isOn: $onlyBad)
                            .onChange(of: onlyBad) { _, _ in apply() }
                    } footer: {
                        Text("开着时,预计 AQI 不超过 100(优、良)就不打扰。")
                    }
                }
            }
            .pageTitle("空气质量提醒")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(lodoAccent.accent)
        .presentationDetents([.medium, .large])
    }

    private func binding(for time: String) -> Binding<Date> {
        Binding(
            get: {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 7, minute: parts.last ?? 0,
                                             second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let updated = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
                timesRaw = AirQualityReminderPlan.encode(times.map { $0 == time ? updated : $0 })
                apply()
            })
    }

    private func apply() {
        AirQualityNotifier.reschedule(AirQualityStore.cached())
        // 后台刷新挂在下一次提醒前一小时(和定时任务共用一个后台任务)。
        RoutineRunner.refreshSchedule(context: context)
        // 缓存里的预报可能不够新(或者还没有明天的),顺手取一次。
        Task { await AirQualityNotifier.refreshIfNeeded() }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
