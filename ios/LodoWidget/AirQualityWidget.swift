import WidgetKit
import SwiftUI
import Charts

// MARK: - 快照(与 app 侧 AirQualityStore.WidgetSnapshot 字段一致)

/// app 写进 App Group 的空气质量快照。小组件不链接 LodoCore、也读不到应用内语言,
/// 所以等级名由 app 按应用内语言写好;数字则由小组件自己按快照里的(取整过的)坐标
/// 向 Open-Meteo 刷新——小组件不能定位,坐标只能来自 app 上次那次。
struct AirQualitySnapshot: Codable {
    struct Hour: Codable {
        let date: Date
        let aqi: Int
    }
    struct Labels: Codable {
        let title: String
        let disabled: String
    }
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double
    var aqi: Int
    var dominant: String?
    var hourly: [Hour]
    var categoryTitles: [String]
    var labels: Labels
    /// 天气(app 用 WeatherKit 查好写进来,小组件自己不查)。老快照没有。
    var weather: Weather?

    struct Weather: Codable {
        struct Hour: Codable {
            let date: Date
            let temperature: Double
            let symbol: String
        }
        let temperature: Double
        let high: Double?
        let low: Double?
        let symbol: String
        let condition: String
        let hourly: [Hour]

        /// 这一刻该显示的温度和图标:当前那份过了一小时就换成逐小时预报里这一小时的。
        func now(at date: Date, fetchedAt: Date) -> (temperature: Double, symbol: String) {
            guard date.timeIntervalSince(fetchedAt) > 3600,
                  let hour = hourly.last(where: { $0.date <= date }) else { return (temperature, symbol) }
            return (hour.temperature, hour.symbol)
        }

        /// 「23°」,单位按系统地区。
        static func format(_ celsius: Double) -> String {
            // 只写「23°」不带 C/F(同系统天气);美制地区换成华氏度。
            let fahrenheit = Locale.current.measurementSystem == .us
            let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
            return "\(Int(value.rounded()))°"
        }
    }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.lodo.app")?
            .appending(path: "widget-air.json")
    }

    static func load() -> AirQualitySnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AirQualitySnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// EPA 分级(同 LodoCore 的 AQICategory,顺序一致)。
    static func categoryIndex(_ aqi: Int) -> Int {
        switch aqi {
        case ..<51: return 0
        case ..<101: return 1
        case ..<151: return 2
        case ..<201: return 3
        case ..<301: return 4
        default: return 5
        }
    }

    static func color(_ aqi: Int) -> Color {
        [Color(red: 0, green: 0.894, blue: 0), Color(red: 0.914, green: 0.722, blue: 0.141),
         Color(red: 1, green: 0.494, blue: 0), Color(red: 1, green: 0, blue: 0),
         Color(red: 0.561, green: 0.247, blue: 0.592), Color(red: 0.494, green: 0, blue: 0.137)][categoryIndex(aqi)]
    }

    func title(_ aqi: Int) -> String {
        let index = Self.categoryIndex(aqi)
        return categoryTitles.indices.contains(index) ? categoryTitles[index] : ""
    }

    /// 这一刻该显示的数字:当前那份已经过了一小时,就用逐小时预报里这一小时的值。
    func aqi(at date: Date) -> Int {
        guard date.timeIntervalSince(fetchedAt) > 3600,
              let hour = hourly.last(where: { $0.date <= date }) else { return aqi }
        return hour.aqi
    }

    /// 按快照里的坐标重新查一次(同 LodoCore `OpenMeteoAirQuality` 的请求,只取小组件要的字段)。
    func refreshed() async -> AirQualitySnapshot? {
        let pollutants = ["pm2_5": "PM2.5", "pm10": "PM10", "ozone": "O₃",
                          "nitrogen_dioxide": "NO₂", "sulphur_dioxide": "SO₂", "carbon_monoxide": "CO"]
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current",
                         value: (["us_aqi"] + pollutants.keys.map { "us_aqi_\($0)" }).joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "us_aqi"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let total = (current["us_aqi"] as? NSNumber)?.doubleValue else { return nil }
        var next = self
        next.fetchedAt = .now
        next.aqi = Int(total.rounded())
        next.dominant = pollutants.compactMap { key, symbol -> (String, Double)? in
            (current["us_aqi_\(key)"] as? NSNumber).map { (symbol, $0.doubleValue) }
        }.max { $0.1 < $1.1 }?.0
        if let block = root["hourly"] as? [String: Any],
           let times = block["time"] as? [Any], let values = block["us_aqi"] as? [Any] {
            next.hourly = zip(times, values).compactMap { time, value in
                guard let seconds = (time as? NSNumber)?.doubleValue,
                      let value = (value as? NSNumber)?.doubleValue else { return nil }
                return Hour(date: Date(timeIntervalSince1970: seconds), aqi: Int(value.rounded()))
            }
        }
        return next
    }

    static let sample = AirQualitySnapshot(
        fetchedAt: .now, latitude: 31.23, longitude: 121.47, aqi: 57, dominant: "PM2.5",
        hourly: (0..<24).map {
            Hour(date: Calendar.current.startOfDay(for: .now).addingTimeInterval(Double($0) * 3600),
                 aqi: [42, 45, 48, 52, 57, 63, 70, 78, 85, 92, 98, 104][$0 % 12])
        },
        categoryTitles: ["优", "良", "对敏感人群不健康", "不健康", "非常不健康", "危险"],
        labels: Labels(title: "天气", disabled: "在 lodo 健康页开启天气与空气质量"),
        weather: Weather(temperature: 23, high: 26, low: 17, symbol: "cloud.sun.fill",
                         condition: "多云", hourly: []))
}

struct AirQualityEntry: TimelineEntry {
    let date: Date
    /// nil = 还没在 app 里开启空气质量。
    let snapshot: AirQualitySnapshot?
}

struct AirQualityProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirQualityEntry {
        AirQualityEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AirQualityEntry) -> Void) {
        let snapshot = AirQualitySnapshot.load()
        completion(AirQualityEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirQualityEntry>) -> Void) {
        Task {
            var snapshot = AirQualitySnapshot.load()
            // 半小时以上没更新就自己刷一次;失败照旧用旧数据(下面按小时预报往后排)。
            if let current = snapshot, Date.now.timeIntervalSince(current.fetchedAt) > 30 * 60,
               let fresh = await current.refreshed() {
                fresh.save()
                snapshot = fresh
            }
            let now = Date()
            // 现在一份,再按逐小时预报在接下来几个整点各放一份——没网也能跟着预报走。
            let hours = (snapshot?.hourly ?? []).map(\.date).filter { $0 > now }.prefix(6)
                + (snapshot?.hourly.isEmpty ?? true
                   ? (snapshot?.weather?.hourly ?? []).map(\.date).filter { $0 > now }.prefix(6) : [])
            let entries = ([now] + hours).map { AirQualityEntry(date: $0, snapshot: snapshot) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
        }
    }
}

// MARK: - 视图

/// 天气 + 空气质量。不再写主要污染物(用户要求去掉「PM2.5」那行说明)。
struct AirQualityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AirQualityEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot, aqi: snapshot.aqi(at: entry.date))
            } else {
                disabled
            }
        }
        .widgetURL(URL(string: "lodo://health"))
    }

    private func current(_ snapshot: AirQualitySnapshot) -> (temperature: Double, symbol: String)? {
        snapshot.weather?.now(at: entry.date, fetchedAt: snapshot.fetchedAt)
    }

    @ViewBuilder
    private func content(_ snapshot: AirQualitySnapshot, aqi: Int) -> some View {
        switch family {
        case .accessoryCircular:
            if let now = current(snapshot) {
                VStack(spacing: 0) {
                    Image(systemName: now.symbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                    Text(AirQualitySnapshot.Weather.format(now.temperature))
                        .font(.headline.monospacedDigit())
                }
                .widgetAccentable()
                .containerBackground(.clear, for: .widget)
            } else {
                Gauge(value: Double(min(aqi, 300)), in: 0...300) {
                    Text("AQI")
                } currentValueLabel: {
                    Text("\(aqi)")
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
                .containerBackground(.clear, for: .widget)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if let now = current(snapshot), let weather = snapshot.weather {
                    HStack(spacing: 4) {
                        Image(systemName: now.symbol)
                        Text(AirQualitySnapshot.Weather.format(now.temperature))
                            .font(.headline.monospacedDigit())
                        Text(weather.condition)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .widgetAccentable()
                    if let range = rangeText(weather) {
                        Text(range).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("AQI \(aqi) · \(snapshot.title(aqi))")
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            if let now = current(snapshot) {
                Text("\(Image(systemName: now.symbol)) \(AirQualitySnapshot.Weather.format(now.temperature)) · AQI \(aqi)")
                    .containerBackground(.clear, for: .widget)
            } else {
                Text("AQI \(aqi) · \(snapshot.title(aqi))")
                    .containerBackground(.clear, for: .widget)
            }
        case .systemMedium:
            HStack(spacing: 14) {
                summary(snapshot, aqi: aqi)
                VStack(alignment: .leading, spacing: 4) {
                    Label(snapshot.title(aqi), systemImage: "aqi.medium")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Chart(snapshot.hourly, id: \.date) { point in
                        BarMark(x: .value("时间", point.date, unit: .hour), y: .value("AQI", point.aqi))
                            .foregroundStyle(AirQualitySnapshot.color(point.aqi))
                            .cornerRadius(2)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) {
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                }
            }
            .homeWidgetBackground()
        default:
            summary(snapshot, aqi: aqi)
                .homeWidgetBackground()
        }
    }

    /// 小号 / 中号左半:上面天气(图标、温度、状况、今天高低),下面一行空气质量。
    private func summary(_ snapshot: AirQualitySnapshot, aqi: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let now = current(snapshot), let weather = snapshot.weather {
                HStack(alignment: .top) {
                    Text(AirQualitySnapshot.Weather.format(now.temperature))
                        .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Image(systemName: now.symbol)
                        .font(.title2)
                        .weatherSymbolStyle(now.symbol)
                }
                Text(weather.condition)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let range = rangeText(weather) {
                    Text(range)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(snapshot.labels.title, systemImage: "cloud.sun")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle()
                    .fill(AirQualitySnapshot.color(aqi))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                Text("AQI \(aqi)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(snapshot.title(aqi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if snapshot.weather != nil {
                // WeatherKit 要求在显示天气数据的地方标出数据来源。
                Text(verbatim: "\u{F8FF}Weather")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rangeText(_ weather: AirQualitySnapshot.Weather) -> String? {
        guard let high = weather.high, let low = weather.low else { return nil }
        return "↑\(AirQualitySnapshot.Weather.format(high)) ↓\(AirQualitySnapshot.Weather.format(low))"
    }

    @ViewBuilder
    private var disabled: some View {
        let text = "在 lodo 健康页开启天气与空气质量"
        switch family {
        case .accessoryInline:
            Text("AQI —").containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "cloud.sun").font(.title3)
            }
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("天气", systemImage: "cloud.sun").font(.caption.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("天气", systemImage: "cloud.sun")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(text).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .homeWidgetBackground()
        }
    }
}

/// 天气(含空气质量):桌面(小/中)+ 锁屏(圆形/长条/一行字)同一个小组件。
/// kind 仍是原来的 "LodoAirQuality",已经摆在桌面上的不会掉。
struct AirQualityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoAirQuality", provider: AirQualityProvider()) { entry in
            AirQualityWidgetView(entry: entry)
        }
        .configurationDisplayName("天气")
        .description("所在地此刻的天气、温度和空气质量(美标 AQI)。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular,
                            .accessoryRectangular, .accessoryInline])
    }
}

#Preview("Small", as: .systemSmall) {
    AirQualityWidget()
} timeline: {
    AirQualityEntry(date: .now, snapshot: .sample)
}

#Preview("Medium", as: .systemMedium) {
    AirQualityWidget()
} timeline: {
    AirQualityEntry(date: .now, snapshot: .sample)
}

#Preview("Circular", as: .accessoryCircular) {
    AirQualityWidget()
} timeline: {
    AirQualityEntry(date: .now, snapshot: .sample)
}

extension View {
    /// 同 app 里的 `weatherSymbolStyle`:多色模式里云是白的、白底上看不见,带云的改用调色板。
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
