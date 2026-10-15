import Foundation
import WidgetKit
import UserNotifications
import LodoCore

/// 空气质量的取数与缓存(健康页、总览、桌面/锁屏小组件共用)。
///
/// - 开关 `AppSettings.airQualityEnabled` 默认关;关着时一个请求都不发。
/// - 位置:单次定位(`LocationHelper`),取整到两位小数(约 1 公里)再发给 Open-Meteo;
///   定位失败时用上次存下的坐标。
/// - 缓存:整份报告存在 App Group(`air-quality.json`),30 分钟内不重复请求;小组件读
///   同一个文件,自己按存下的坐标刷新(它不能定位),见 LodoWidget 的 AirQualityWidget。
@MainActor
enum AirQualityStore {
    enum Failure: Equatable {
        /// 拿不到位置,也没有存过坐标。
        case location
        case network
    }

    /// 小组件快照。字段与 LodoWidget 的 `AirQualitySnapshot` 保持一致(小组件不链接
    /// LodoCore,也读不到应用内语言——等级名、建议都由 app 按应用内语言写好)。
    struct WidgetSnapshot: Codable, Equatable {
        struct Hour: Codable, Equatable {
            let date: Date
            let aqi: Int
        }
        var fetchedAt: Date
        var latitude: Double
        var longitude: Double
        var aqi: Int
        var dominant: String?
        var hourly: [Hour]
        /// 六个等级各自的名字(按 AQICategory 的顺序)和建议,小组件自己刷新出新数字时用。
        var categoryTitles: [String]
        var labels: Labels
        /// 天气(WeatherKit,app 这边查好写进来;小组件自己只能刷新空气质量)。老快照没有。
        var weather: Weather?

        struct Weather: Codable, Equatable {
            struct Hour: Codable, Equatable {
                let date: Date
                let temperature: Double
                let symbol: String
            }
            /// 摄氏度;小组件按系统地区换算显示。
            let temperature: Double
            let high: Double?
            let low: Double?
            let symbol: String
            let condition: String
            let hourly: [Hour]
        }

        struct Labels: Codable, Equatable {
            let title: String
            let disabled: String
        }
    }

    nonisolated private static var cacheURL: URL? { AppGroup.containerURL?.appending(path: "air-quality.json") }
    static var widgetSnapshotURL: URL? { AppGroup.containerURL?.appending(path: "widget-air.json") }
    static let widgetKind = "LodoAirQuality"

    private static var inFlight: Task<Result<AirQualityReport, AirQualityError>, Never>?

    struct AirQualityError: Error, Equatable { let failure: Failure }

    /// 读文件而已,不碰主线程状态,视图初始化时也能直接调。
    nonisolated static func cached() -> AirQualityReport? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AirQualityReport.self, from: data)
    }

    /// 取一份报告:缓存够新就直接用,否则重新定位 + 请求。并发调用共用同一次请求。
    static func refresh(force: Bool = false) async -> Result<AirQualityReport, AirQualityError> {
        guard AppSettings.airQualityEnabled else { return .failure(.init(failure: .network)) }
        // 天气和空气质量一起刷新:天气还没有(刚升级、上次查失败)时也要重查。
        if !force, let cached = cached(), cached.isFresh(now: .now),
           let weather = WeatherStore.cached(),
           Date.now.timeIntervalSince(weather.fetchedAt) < AirQualityReport.freshness {
            return .success(cached)
        }
        if let inFlight { return await inFlight.value }
        let task = Task { await fetch() }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    private static func fetch() async -> Result<AirQualityReport, AirQualityError> {
        let previous = cached()
        let coordinate = await LocationHelper.requestCoordinate()
        guard let latitude = coordinate?.latitude ?? previous?.latitude,
              let longitude = coordinate?.longitude ?? previous?.longitude else {
            return .failure(.init(failure: .location))
        }
        let lat = OpenMeteoAirQuality.rounded(latitude)
        let lon = OpenMeteoAirQuality.rounded(longitude)
        // 天气和空气质量并行查,哪个失败都不拖累另一个。
        async let weather = WeatherStore.fetch(latitude: lat, longitude: lon)
        guard let url = OpenMeteoAirQuality.url(latitude: lat, longitude: lon) else {
            return .failure(.init(failure: .network))
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("lodo-ios (https://github.com/Lu-Zhan/lodo)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              var report = try? OpenMeteoAirQuality.parse(data) else {
            _ = await weather
            return .failure(.init(failure: .network))
        }
        _ = await weather
        // 存查询用的坐标,不存接口返回的网格点坐标:小组件拿它原样再查一次。
        report.latitude = lat
        report.longitude = lon
        save(report)
        AirQualityNotifier.reschedule(report)
        return .success(report)
    }

    private static func save(_ report: AirQualityReport) {
        if let url = cacheURL, let data = try? JSONEncoder().encode(report) {
            try? data.write(to: url, options: .atomic)
        }
        writeWidgetSnapshot(report)
    }

    /// 关掉开关:删掉缓存和坐标(小组件随即显示"未开启"),不再请求。
    static func disable() {
        for url in [cacheURL, widgetSnapshotURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        WeatherStore.disable()
        AirQualityNotifier.reschedule(nil)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// 应用内语言换了,小组件上的等级名跟着换。
    static func writeWidgetSnapshot(_ report: AirQualityReport?) {
        guard let url = widgetSnapshotURL else { return }
        let locale = AppSettings.language.locale
        let labels = WidgetSnapshot.Labels(
            title: String(localized: "天气", bundle: .appLanguage(), locale: locale),
            disabled: String(localized: "在 lodo 健康页开启天气与空气质量", bundle: .appLanguage(), locale: locale))
        guard let report else { return }
        let snapshot = WidgetSnapshot(
            fetchedAt: report.fetchedAt, latitude: report.latitude, longitude: report.longitude,
            aqi: report.aqi, dominant: report.dominant?.symbol,
            // 小组件的图只画今天;往后的整点也只排今天的预报。
            hourly: report.todayHourly(now: .now).map { .init(date: $0.date, aqi: $0.aqi) },
            categoryTitles: AQICategory.allCases.map(title),
            labels: labels,
            weather: WeatherStore.cached().map { weather in
                WidgetSnapshot.Weather(
                    temperature: weather.temperature, high: weather.high, low: weather.low,
                    symbol: weather.symbol, condition: weather.condition,
                    hourly: weather.hourly.map { .init(date: $0.date, temperature: $0.temperature,
                                                       symbol: $0.symbol) })
            })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// 等级名按应用内语言(`AQICategory.title` 是 String Catalog 的 key)。
    static func title(_ category: AQICategory) -> String {
        String(localized: String.LocalizationValue(category.title), bundle: .appLanguage(),
               locale: AppSettings.language.locale)
    }

    static func advice(_ category: AQICategory) -> String {
        String(localized: String.LocalizationValue(category.advice), bundle: .appLanguage(),
               locale: AppSettings.language.locale)
    }
}

/// 空气质量提醒的本地通知(见 `AirQualityReminderPlan`)。标识前缀 `air-quality-`,
/// 最多 `maxTimes` 条;每次取到新预报、改了提醒设置时整批重排。
@MainActor
enum AirQualityNotifier {
    static let prefix = "air-quality-"

    static var times: [String] {
        AirQualityReminderPlan.parseTimes(
            UserDefaults.standard.string(forKey: AppSettings.airQualityReminderTimesKey) ?? "")
    }

    static var isActive: Bool { AppSettings.airQualityEnabled && !times.isEmpty }

    /// 回前台/后台刷新时调:开着提醒才去取(缓存 30 分钟内不重复请求),取到就会顺手重排。
    static func refreshIfNeeded() async {
        guard isActive else { return }
        if case .success(let report) = await AirQualityStore.refresh() { reschedule(report) }
    }

    /// 下一次提醒前一小时:后台刷新挂在这儿,争取用上最新的预报。
    static var nextRefreshDate: Date? {
        guard isActive else { return nil }
        let now = Date()
        return times.compactMap { time -> Date? in
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2,
                  var fire = Calendar.current.date(bySettingHour: parts[0], minute: parts[1],
                                                   second: 0, of: now) else { return nil }
            if fire <= now { fire = fire.addingTimeInterval(86400) }
            return fire.addingTimeInterval(-3600)
        }.min().map { max($0, now.addingTimeInterval(15 * 60)) }
    }

    static func reschedule(_ report: AirQualityReport?) {
        let slots = contents(for: report)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for slot in slots {
                let content = UNMutableNotificationContent()
                content.title = slot.title
                content.body = slot.body
                content.sound = .default
                content.userInfo = ["route": "health"]
                center.add(UNNotificationRequest(
                    identifier: slot.id, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: max(1, slot.date.timeIntervalSinceNow), repeats: false)))
            }
        }
    }

    /// 要排的那几条(标识、标题、正文、时刻);提醒没开或没有预报时为空。
    static func contents(for report: AirQualityReport?) -> [(id: String, title: String, body: String, date: Date)] {
        let locale = AppSettings.language.locale
        let slots: [(id: String, title: String, body: String, date: Date)]
        if isActive, let report {
            let planned = AirQualityReminderPlan.slots(
                times: times, hourly: report.hourly, now: .now,
                onlyWhenUnhealthy: UserDefaults.standard.bool(forKey: AppSettings.airQualityReminderOnlyBadKey))
            slots = planned.map { slot in
                let tips = slot.tips.map {
                    String(localized: String.LocalizationValue($0.text), bundle: .appLanguage(), locale: locale)
                }
                let separator = AppSettings.language == .en ? ", " : ","
                // 英文的几条建议是小写开头(拼在一句里),整句首字母大写。
                var joined = tips.joined(separator: separator)
                if let first = joined.first { joined = first.uppercased() + joined.dropFirst() }
                return (prefix + slot.time.replacingOccurrences(of: ":", with: ""),
                        String(localized: "空气质量:\(AirQualityStore.title(slot.category))",
                               bundle: .appLanguage(), locale: locale),
                        String(localized: "AQI \(slot.aqi) · \(joined)",
                               bundle: .appLanguage(), locale: locale),
                        slot.fireDate)
            }
        } else {
            slots = []
        }
        return slots
    }
}
