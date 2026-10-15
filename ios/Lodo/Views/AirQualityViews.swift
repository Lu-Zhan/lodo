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
    /// 天气和空气质量一起取(同一个开关、同一个坐标,见 `WeatherStore`)。
    @State private var weather: WeatherReport? = WeatherStore.cached()
    @State private var attribution: WeatherAttribution?
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
                    Text("正在获取天气与空气质量…").foregroundStyle(.secondary)
                }
            } else if let failure {
                failureRow(failure)
            }
        } header: {
            HStack(spacing: 16) {
                Text("天气与空气质量")
                Spacer()
                if enabled {
                    // 刷新 | 提醒 | 其他,都摆在标题行右上角;刷新请求中换成转圈。
                    Button { Task { await load(force: true) } } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loading)
                    .accessibilityLabel("刷新")
                    // 提醒也摆在标题行上(开着时铃铛是实心的),菜单里只剩关闭。
                    Button { showsReminders = true } label: {
                        Image(systemName: AirQualityReminderPlan.parseTimes(reminderTimes).isEmpty
                              ? "bell" : "bell.fill")
                    }
                    .accessibilityLabel("提醒设置")
                    Menu {
                        Button("关闭天气与空气质量", systemImage: "xmark.circle", role: .destructive) {
                            confirmingDisable = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("天气与空气质量选项")
                }
            }
            // sheet/确认框/task 挂在标题行上:挂在 Section 上会分摊到每一行(task 跑好几遍,sheet 弹不出来)。
            .sheet(isPresented: $showsReminders) { AirQualityReminderSettingsView() }
            .confirmationDialog("关闭天气与空气质量?", isPresented: $confirmingDisable, titleVisibility: .visible) {
                Button("关闭", role: .destructive) {
                    enabled = false
                    report = nil
                    weather = nil
                    AirQualityStore.disable()
                }
            } message: {
                Text("健康页、总览和小组件都不再显示天气与空气质量,也不再使用位置。")
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
                // 一行:左边更新时间,苹果天气标识靠右(用户要求)。
                HStack(spacing: 8) {
                    Text("更新于 \(report.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    Spacer(minLength: 8)
                    if weather != nil, let attribution {
                        WeatherAttributionView(attribution: attribution)
                    }
                }
            }
        }
    }

    private var disabledRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("所在地今天的天气与空气质量", systemImage: "cloud.sun")
                .font(.body.weight(.medium))
            Text("天气来自苹果天气,空气质量按美国 EPA 标准显示 AQI。会把约 1 公里精度的位置发给苹果天气和 Open-Meteo 查询,不涉及健康数据。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("显示天气与空气质量") {
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
        // 第一行:左边天气(温度,下面最高最低),右边空气指数,两边底部对齐(用户要求)。
        HStack(alignment: .bottom) {
            if let weather {
                WeatherNowView(weather: weather)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                AQIBadge(aqi: report.aqi, font: .system(size: weather == nil ? 44 : 30,
                                                        weight: .semibold, design: .rounded))
                Text(AirQualityStore.title(report.category))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)

        // 第二行:未来 3 天。
        if let days = weather?.daily, !days.isEmpty {
            HStack(spacing: 0) {
                ForEach(days.prefix(3), id: \.date) { day in
                    WeatherDayView(day: day)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }

        // 第三行:今天逐小时的 AQI,右边 PM2.5 / PM10 / NO₂。
        HStack(alignment: .center, spacing: 12) {
            if !report.todayHourly(now: .now).isEmpty {
                AirQualityHourlyChart(hourly: report.todayHourly(now: .now))
                    .frame(height: 80)
            } else {
                Spacer()
            }
            VStack(alignment: .trailing, spacing: 4) {
                concentration("PM2.5", report.pm2_5)
                concentration("PM10", report.pm10)
                concentration("NO₂", report.nitrogenDioxide)
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    /// 「25 PM2.5」一行(微克每立方米)。
    private func concentration(_ symbol: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.body.weight(.medium).monospacedDigit())
            Text(symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 40, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("微克每立方米")
    }

    private func load(force: Bool) async {
        guard enabled else { return }
        loading = true
        defer { loading = false }
        switch await AirQualityStore.refresh(force: force) {
        case .success(let fresh):
            withAnimation(.lodoAware(.snappy)) {
                report = fresh
                weather = WeatherStore.cached()
            }
            failure = nil
            if attribution == nil { attribution = await WeatherStore.attribution() }
        case .failure(let error):
            // 刷新失败时旧数据照样摆着(footer 写着更新时间),没有旧数据才报错。
            if report == nil { failure = error.failure }
        }
    }
}

/// 天气那一行:大号温度 + 图标,状况和今天最高最低。
struct WeatherRow: View {
    let weather: WeatherReport
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: weather.symbol)
                .weatherSymbolStyle(weather.symbol)
                .font(.system(size: compact ? 28 : 36))
            VStack(alignment: .leading, spacing: 2) {
                Text(WeatherStore.format(weather.temperature))
                    .font(.system(size: compact ? 30 : 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(weather.condition)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                // 总览小卡片只有半宽,最高最低挪到状况下面一行。
                if compact, let high = weather.high, let low = weather.low {
                    Text(verbatim: "↑\(WeatherStore.format(high)) ↓\(WeatherStore.format(low))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !compact, let high = weather.high, let low = weather.low {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("最高 \(WeatherStore.format(high))")
                    Text("最低 \(WeatherStore.format(low))")
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 健康页第一行左半:图标 + 当前温度,温度下面是状况和今天最高最低。
struct WeatherNowView: View {
    let weather: WeatherReport

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Image(systemName: weather.symbol)
                .weatherSymbolStyle(weather.symbol)
                .font(.system(size: 36))
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(WeatherStore.format(weather.temperature))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Text(weather.condition)
                        .font(.subheadline.weight(.medium))
                    if let high = weather.high, let low = weather.low {
                        Text(verbatim: "↑\(WeatherStore.format(high)) ↓\(WeatherStore.format(low))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 未来某一天:星期、图标、最高/最低。
struct WeatherDayView: View {
    let day: WeatherReport.Day

    var body: some View {
        VStack(spacing: 4) {
            Text(day.date, format: .dateTime.weekday(.abbreviated).locale(AppSettings.language.locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: day.symbol)
                .weatherSymbolStyle(day.symbol)
                .font(.title3)
                .frame(height: 26)
            Text(verbatim: "\(WeatherStore.format(day.high)) / \(WeatherStore.format(day.low))")
                .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

/// WeatherKit 要求的数据来源标识:苹果天气的标识 + 法律信息链接。
struct WeatherAttributionView: View {
    let attribution: WeatherAttribution
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: colorScheme == .dark ? attribution.darkMark : attribution.lightMark) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Text(verbatim: "\u{F8FF}Weather")
            }
            .frame(height: 12)
            // Link 在分区 footer 里不继承 footer 的字号,显式和旁边「更新于」一致。
            Link("数据来源", destination: attribution.legalPage)
                .font(.footnote)
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
    let weather: WeatherReport?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .airQuality, action: action) {
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    if let weather {
                        WeatherRow(weather: weather, compact: true)
                        HStack(spacing: 6) {
                            AQIBadge(aqi: report.aqi, font: .headline)
                            Text(AirQualityStore.title(report.category))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        AQIBadge(aqi: report.aqi, font: .system(size: size == .small ? 36 : 40,
                                                                weight: .semibold, design: .rounded))
                        Text(AirQualityStore.title(report.category))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                    }
                    if size == .large {
                        Text(AirQualityStore.advice(report.category))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !report.todayHourly(now: .now).isEmpty {
                            AirQualityHourlyChart(hourly: report.todayHourly(now: .now), showsAxis: false)
                                .frame(height: 48)
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: enabled ? "正在获取天气与空气质量…" : "在健康页开启天气与空气质量后显示")
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

extension View {
    /// 天气图标。多色模式里云是白的,白底卡片上看不见,所以带云的图标改用调色板:
    /// 云画成次要灰,太阳/闪电黄、月亮靛、雨雪蓝;不带云的(晴、月亮…)照旧多色。
    @ViewBuilder
    func weatherSymbolStyle(_ name: String) -> some View {
        if name.contains("cloud") || name.contains("fog") || name.contains("smoke") || name.contains("wind") {
            let second: Color = name.contains("sun") || name.contains("bolt") ? .yellow
                : name.contains("moon") ? .indigo : .cyan
            symbolRenderingMode(.palette)
                .foregroundStyle(Color.secondary, second)
        } else {
            symbolRenderingMode(.multicolor)
        }
    }
}
