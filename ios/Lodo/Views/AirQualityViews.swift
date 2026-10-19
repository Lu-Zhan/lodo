import SwiftUI
import Charts
import UserNotifications
import LodoCore

// 空气质量(美标 AQI,Open-Meteo):健康页的一组 + 总览的一个模块。取数在 AirQualityStore。

extension AQICategory {
    /// EPA 等级色。只用在色块/圆点/柱子上,**不拿来写字**——「良」那档就算换成了柔和的黄,白底上当字色仍然读不清。
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
    @State private var confirmingEnable = false
    @State private var showsReminders = false
    @AppStorage(AppSettings.airQualityReminderTimesKey) private var reminderTimes = ""

    var body: some View {
        Section {
            if !enabled {
                disabledRow
            } else if report != nil || weather != nil {
                // 天气和空气质量各自有就各自显示:哪个请求失败都不拖累另一个。
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
                    // 原来是刷新 | 铃铛 | 更多三颗图标,含义难猜:收成一个文字菜单。
                    // 刷新请求中旁边转个圈(旧内容不清空)。
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                    Menu {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await load(force: true) }
                        }
                        .disabled(loading)
                        Button(AirQualityReminderPlan.parseTimes(reminderTimes).isEmpty
                               ? LocalizedStringKey("提醒设置:未开启") : LocalizedStringKey("提醒设置:已开启"),
                               systemImage: "bell") {
                            showsReminders = true
                        }
                        Divider()
                        Button("关闭天气与空气质量", systemImage: "xmark.circle", role: .destructive) {
                            confirmingDisable = true
                        }
                    } label: {
                        Text("选项")
                            .font(.subheadline)
                            .textCase(nil)
                    }
                    .accessibilityLabel("天气与空气质量选项")
                }
            }
            // sheet/确认框/task 挂在标题行上:挂在 Section 上会分摊到每一行(task 跑好几遍,sheet 弹不出来)。
            .sheet(isPresented: $showsReminders) { AirQualityReminderSettingsView() }
            // 关闭态只有一行「显示」:点了先说清楚要用位置、发给谁,再开。
            .alert("显示天气与空气质量?", isPresented: $confirmingEnable) {
                Button("取消", role: .cancel) {}
                Button("显示") {
                    enabled = true
                    Task { await load(force: true) }
                }
            } message: {
                Text("天气来自苹果天气,空气质量按美国 EPA 标准显示 AQI。会把约 1 公里精度的位置发给苹果天气和 Open-Meteo 查询,不涉及健康数据。")
            }
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
            if enabled, report != nil || weather != nil {
                // 一行:左边更新时间(空气质量那份的),苹果天气标识靠右(用户要求);
                // 只有天气时就只挂署名。
                HStack(spacing: 8) {
                    updatedText
                    Spacer(minLength: 8)
                    if weather != nil, let attribution {
                        WeatherAttributionView(attribution: attribution)
                    }
                }
            }
        }
    }

    /// 更新时间:天气和空气质量各取各的,时间差不多(10 分钟内)时只写一个;不是今天的带上日期。
    @ViewBuilder
    private var updatedText: some View {
        let air = report?.fetchedAt
        let sky = weather?.fetchedAt
        if let air, let sky, abs(air.timeIntervalSince(sky)) > 600 {
            Text("天气 \(Self.stamp(sky)) · 空气质量 \(Self.stamp(air))")
        } else if let time = air ?? sky {
            Text("更新于 \(Self.stamp(time))")
        }
    }

    private static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 关着时只占一行(原来是一整张介绍卡):用途和隐私说明放进点「显示」之后的确认框。
    private var disabledRow: some View {
        HStack {
            Label("所在地的天气与空气质量", systemImage: "cloud.sun")
                .foregroundStyle(.secondary)
            Spacer()
            Button("显示") { confirmingEnable = true }
                .buttonStyle(.borderless)
        }
    }

    private func failureRow(_ failure: AirQualityStore.Failure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 分开写两支 Text:三元的两支都是 String,会挑到 verbatim 重载、进不了字符串目录。
            Group {
                if failure == .location {
                    Text("无法获取位置")
                } else {
                    Text("空气质量获取失败")
                }
            }
            .font(.body.weight(.medium))
            Group {
                if failure == .location {
                    Text("在系统设置里允许 lodo 使用位置后重试。")
                } else {
                    Text("检查网络后下拉刷新重试。")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button("重试") { Task { await load(force: true) } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func reportRows(_ report: AirQualityReport?) -> some View {
        // 第一行:左边天气(温度,下面最高最低),右边空气指数,两边底部对齐(用户要求)。
        HStack(alignment: .bottom) {
            if let weather {
                WeatherNowView(weather: weather)
            }
            Spacer(minLength: 8)
            if let report {
                VStack(alignment: .trailing, spacing: 2) {
                    AQIBadge(aqi: report.aqi, font: .system(size: weather == nil ? 44 : 30,
                                                            weight: .semibold, design: .rounded))
                    Text(AirQualityStore.title(report.category))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if !loading {
                // 只拿到了天气:空气质量那一半如实说一声,下拉可以重试。
                Text("空气质量暂时取不到")
                    .font(.subheadline)
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

        // 第三行:当前的 PM2.5 / PM10 / NO₂。只报此刻,不画逐小时变化(用户要求)。
        if let report {
            HStack(spacing: 0) {
                concentration("PM2.5", report.pm2_5)
                    .frame(maxWidth: .infinity)
                concentration("PM10", report.pm10)
                    .frame(maxWidth: .infinity)
                concentration("NO₂", report.nitrogenDioxide)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
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
            // 空气质量失败不等于天气也失败:天气那份(和它并行取的)照样拿出来显示。
            weather = WeatherStore.cached() ?? weather
            if weather != nil, attribution == nil { attribution = await WeatherStore.attribution() }
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

// MARK: - 总览

struct OverviewAirQualityWidget: View {
    let size: OverviewWidgetSize
    /// nil = 还没开或没取到。
    let report: AirQualityReport?
    let weather: WeatherReport?
    let enabled: Bool
    var loading = false
    /// 最近一次刷新失败的原因;有旧数据时照样显示旧数据,只在底下注明。
    var failure: AirQualityStore.Failure? = nil
    let now: Date
    let action: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .airQuality, action: action) {
            if !enabled {
                OverviewEmptyText(text: "在健康页开启天气与空气质量后显示")
            } else if report == nil && weather == nil {
                if loading {
                    OverviewEmptyText(text: "正在获取天气与空气质量…")
                } else {
                    OverviewEmptyText(text: failure == .location ? "拿不到位置,下拉刷新重试"
                                                                  : "暂时没取到,下拉刷新重试")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // 天气和空气质量是两个独立请求:哪边有就显示哪边,不互相拖累。
                    if let weather {
                        WeatherRow(weather: weather, compact: true)
                    }
                    if let report {
                        if weather != nil {
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
                    }
                    if size == .large {
                        if let report {
                            Text(AirQualityStore.advice(report.category))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        nextHoursChart
                    }
                    footer
                }
            }
        }
    }

    /// 接下来 12 小时:上面温度曲线、下面 AQI 色带,共用一条时间轴(上下分开画,
    /// 不做双 Y 轴——两个量纲叠在一起没法读)。图在 `OverviewHourlyForecast`。
    @ViewBuilder
    private var nextHoursChart: some View {
        let points = OverviewCharts.nextHours(
            temperatures: weather?.hourly.map { ($0.date, $0.temperature) } ?? [],
            aqi: report?.hourly.map { ($0.date, $0.aqi) } ?? [],
            now: now)
        if !points.isEmpty {
            OverviewHourlyForecast(points: points)
                .padding(.top, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(nextHoursSummary(points))
        }
    }

    private func nextHoursSummary(_ points: [OverviewHourPoint]) -> Text {
        let temps = points.compactMap(\.temperature)
        let peak = points.filter { $0.aqi != nil }.max { ($0.aqi ?? 0) < ($1.aqi ?? 0) }
        var text = Text("接下来 12 小时")
        if let low = temps.min(), let high = temps.max() {
            text = text + Text(verbatim: ", \(WeatherStore.format(low))–\(WeatherStore.format(high))")
        }
        if let peak, let aqi = peak.aqi {
            text = text + Text(",") + Text("AQI 最高 \(aqi)(\(LocalizedContent.time(peak.date)))")
        }
        return text
    }

    /// 底部一行:数据旧了/这次没刷新成功时写更新时间;有天气就挂苹果天气的署名
    /// (WeatherKit 要求;完整的法律链接在健康页那一组的 footer 里)。
    @ViewBuilder
    private var footer: some View {
        let fetched = [report?.fetchedAt, weather?.fetchedAt].compactMap { $0 }.min()
        let stale = fetched.map { now.timeIntervalSince($0) > 3600 } ?? false
        if stale || failure != nil || weather != nil {
            HStack(spacing: 6) {
                if let fetched, stale || failure != nil {
                    Text("更新于 \(LocalizedContent.time(fetched))")
                }
                Spacer(minLength: 0)
                if weather != nil {
                    Text(verbatim: "\u{F8FF}Weather")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }
}

/// 总览空气质量大卡里的「接下来 12 小时」。
///
/// - 温度:平滑曲线 + 往下渐隐的面积,线色按高低从冷蓝过渡到暖橙;每 3 小时标一个读数,
///   第一个点(现在)画成实心大点。
/// - AQI:一条按小时分段的色带(EPA 等级色只上色块,读数用次要色写在上面),
///   一眼看出接下来哪几个小时空气变差——原来的柱状图在 AQI 都差不多时就是一排等高的黄柱子。
/// 两张图 x 轴同一个范围、点都落在每小时的正中,上下对得齐。
struct OverviewHourlyForecast: View {
    let points: [OverviewHourPoint]

    private static let cool = Color(red: 0.33, green: 0.62, blue: 0.96)
    private static let warm = Color(red: 1.0, green: 0.55, blue: 0.16)

    private func mid(_ date: Date) -> Date { date.addingTimeInterval(1800) }
    private var domain: ClosedRange<Date> {
        let first = points.first?.date ?? .now
        let last = points.last?.date ?? first
        return first...last.addingTimeInterval(3600)
    }
    /// 标读数/时刻的那几个小时:现在起每 3 小时一个。
    private var labeled: [OverviewHourPoint] {
        points.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
    }
    private var temps: [Double] { points.compactMap(\.temperature) }
    private var aqis: [Int] { points.compactMap(\.aqi) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            legend
            if !temps.isEmpty {
                temperatureChart
                    .frame(height: 74)
            }
            if !aqis.isEmpty {
                aqiStrip
            } else {
                axisOnly
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Text("接下来 12 小时")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let low = temps.min(), let high = temps.max() {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(LinearGradient(colors: [Self.cool, Self.warm],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 14, height: 4)
                    Text(verbatim: "\(WeatherStore.format(low)) – \(WeatherStore.format(high))")
                        .monospacedDigit()
                }
            }
            if let low = aqis.min(), let high = aqis.max() {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AQICategory(aqi: high).color)
                        .frame(width: 10, height: 10)
                    Text(verbatim: low == high ? "AQI \(high)" : "AQI \(low)–\(high)")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var temperatureChart: some View {
        let low = temps.min() ?? 0
        let high = temps.max() ?? 0
        let span = max(high - low, 1)
        // 上面留出写读数的地方,下面给渐隐的面积留一截底。
        let floor = low - span * 0.45 - 1
        let ceiling = high + span * 0.55 + 1
        let tempPoints = points.filter { $0.temperature != nil }
        let firstDate = points.first?.date
        return Chart {
            ForEach(tempPoints) { point in
                AreaMark(x: .value("时间", mid(point.date)),
                         yStart: .value("温度", floor),
                         yEnd: .value("温度", point.temperature ?? 0),
                         series: .value("系列", "area"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Self.warm.opacity(0.22), Self.warm.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", mid(point.date)),
                         y: .value("温度", point.temperature ?? 0),
                         series: .value("系列", "line"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(LinearGradient(colors: [Self.cool, Self.warm],
                                                    startPoint: .bottom, endPoint: .top))
            }
            ForEach(labeled.filter { $0.temperature != nil }) { point in
                let isNow = point.date == firstDate
                PointMark(x: .value("时间", mid(point.date)),
                          y: .value("温度", point.temperature ?? 0))
                    .symbol {
                        Circle()
                            .fill(isNow ? Self.warm : OverviewWidgetCard<EmptyView>.cardFill)
                            .overlay(Circle().strokeBorder(Self.warm, lineWidth: 2))
                            .frame(width: isNow ? 9 : 7, height: isNow ? 9 : 7)
                    }
            }
        }
        // 读数自己按坐标摆:PointMark 的 annotation 在自定义 symbol + 平滑曲线下会漂走(实测)。
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame.map({ geo[$0] }) {
                    ForEach(labeled.filter { $0.temperature != nil }) { point in
                        if let x = proxy.position(forX: mid(point.date)),
                           let y = proxy.position(forY: point.temperature ?? 0) {
                            let isNow = point.date == firstDate
                            Text(WeatherStore.format(point.temperature ?? 0))
                                .font(.caption.weight(isNow ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(isNow ? .primary : .secondary)
                                .fixedSize()
                                .position(x: plot.minX + x, y: plot.minY + y - 13)
                        }
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: floor...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    private var aqiStrip: some View {
        // 分段之间留一道细缝(约 4 分钟),一段一小时。
        let gap: TimeInterval = 240
        return Chart {
            ForEach(points.filter { $0.aqi != nil }) { point in
                RectangleMark(xStart: .value("开始", point.date.addingTimeInterval(gap / 2)),
                              xEnd: .value("结束", point.date.addingTimeInterval(3600 - gap / 2)),
                              yStart: .value("AQI", 0),
                              yEnd: .value("AQI", 1))
                    .foregroundStyle(AQICategory(aqi: point.aqi ?? 0).color)
                    .cornerRadius(3)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 12)
        // 色带上方写读数、下方写时刻,都按同一个坐标换算摆上去(轴标签和 annotation
        // 的对齐方式在不同系统/外观下不一致,实测"现在"会偏到右边、深色下读数不显示)。
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame.map({ geo[$0] }) {
                    ForEach(labeled) { point in
                        if let x = proxy.position(forX: mid(point.date)) {
                            if let aqi = point.aqi {
                                Text(verbatim: "\(aqi)")
                                    .font(.caption2.weight(point.id == points.first?.id ? .semibold : .regular)
                                        .monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .position(x: plot.minX + x, y: plot.minY - 9)
                            }
                            hourLabel(point)
                                .position(x: plot.minX + x, y: plot.maxY + 12)
                        }
                    }
                }
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    /// 没有 AQI 时只画一条时刻轴,温度曲线照样有个参照。
    private var axisOnly: some View {
        Chart(points) { point in
            RuleMark(x: .value("时间", mid(point.date))).opacity(0)
        }
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 1)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame.map({ geo[$0] }) {
                    ForEach(labeled) { point in
                        if let x = proxy.position(forX: mid(point.date)) {
                            hourLabel(point)
                                .position(x: plot.minX + x, y: plot.maxY + 10)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func hourLabel(_ point: OverviewHourPoint) -> some View {
        Group {
            if point.id == points.first?.id {
                Text("现在").fontWeight(.semibold).foregroundStyle(.primary)
            } else {
                Text(point.date, format: .dateTime.hour().locale(AppSettings.language.locale))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize()
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
