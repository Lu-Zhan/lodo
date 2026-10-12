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
        [Color(red: 0, green: 0.894, blue: 0), Color(red: 1, green: 1, blue: 0),
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
        labels: Labels(title: "空气质量", disabled: "在 lodo 健康页开启空气质量"))
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
            let entries = ([now] + hours).map { AirQualityEntry(date: $0, snapshot: snapshot) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
        }
    }
}

// MARK: - 视图

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

    @ViewBuilder
    private func content(_ snapshot: AirQualitySnapshot, aqi: Int) -> some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(aqi, 300)), in: 0...300) {
                Text("AQI")
            } currentValueLabel: {
                Text("\(aqi)")
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(snapshot.labels.title, systemImage: "aqi.medium")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(aqi)")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(snapshot.title(aqi))
                        .font(.caption)
                        .lineLimit(1)
                }
                if let dominant = snapshot.dominant {
                    Text(dominant)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            Text("AQI \(aqi) · \(snapshot.title(aqi))")
                .containerBackground(.clear, for: .widget)
        case .systemMedium:
            HStack(spacing: 14) {
                summary(snapshot, aqi: aqi)
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
            .containerBackground(.fill.tertiary, for: .widget)
        default:
            summary(snapshot, aqi: aqi)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    private func summary(_ snapshot: AirQualitySnapshot, aqi: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.labels.title, systemImage: "aqi.medium")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(AirQualitySnapshot.color(aqi))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                Text("\(aqi)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
            }
            Text(snapshot.title(aqi))
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let dominant = snapshot.dominant {
                Text(dominant)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var disabled: some View {
        let text = "在 lodo 健康页开启空气质量"
        switch family {
        case .accessoryInline:
            Text("AQI —").containerBackground(.clear, for: .widget)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "aqi.medium").font(.title3)
            }
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("空气质量", systemImage: "aqi.medium").font(.caption.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("空气质量", systemImage: "aqi.medium")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(text).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

/// 空气质量:桌面(小/中)+ 锁屏(圆形/长条/一行字)同一个小组件。
struct AirQualityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoAirQuality", provider: AirQualityProvider()) { entry in
            AirQualityWidgetView(entry: entry)
        }
        .configurationDisplayName("空气质量")
        .description("所在地此刻的美标 AQI 和今天逐小时的变化。")
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
