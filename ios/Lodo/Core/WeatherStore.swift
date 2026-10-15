import Foundation
import CoreLocation
import OSLog
import WeatherKit
import LodoCore

/// 所在地的天气(WeatherKit)。和空气质量**同一个开关、同一个坐标、一起刷新**:
/// `AirQualityStore.fetch` 取到空气质量后顺手查一次,结果一起写进小组件快照。
/// 天气失败不影响空气质量(反之亦然)。
///
/// 发给苹果天气服务的是同一份取整到两位小数的坐标(约 1 公里)。缓存在 App Group
/// `weather.json`,可重算的派生数据,不进备份。
struct WeatherReport: Codable, Equatable {
    struct Hour: Codable, Equatable {
        let date: Date
        /// 摄氏度。
        let temperature: Double
        let symbol: String
    }

    var fetchedAt: Date
    var temperature: Double
    /// 今天(当地)最高 / 最低,摄氏度。
    var high: Double?
    var low: Double?
    /// SF Symbol 名(WeatherKit 给的)。
    var symbol: String
    /// 天气状况的文字(WeatherKit 按系统语言给)。
    var condition: String
    /// 接下来 24 小时逐小时的温度,小组件按它往后排时间线。
    var hourly: [Hour]
}

/// WeatherKit 要求在显示数据的地方标出苹果天气的标识和法律信息链接。
struct WeatherAttribution: Equatable {
    let lightMark: URL
    let darkMark: URL
    let legalPage: URL
}

@MainActor
enum WeatherStore {
    private static let log = Logger(subsystem: "com.lodo.app", category: "Weather")
    nonisolated private static var cacheURL: URL? { AppGroup.containerURL?.appending(path: "weather.json") }

    nonisolated static func cached() -> WeatherReport? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WeatherReport.self, from: data)
    }

    /// 按(已取整的)坐标查一次。失败返回 nil、旧缓存留着。
    static func fetch(latitude: Double, longitude: Double) async -> WeatherReport? {
        #if DEBUG
        // 截图核对:不走 WeatherKit(没开通能力的签名在模拟器上会鉴权失败),塞一份样板。
        if ProcessInfo.processInfo.arguments.contains("--demo-weather") {
            let now = Date()
            let report = WeatherReport(
                fetchedAt: now, temperature: 23, high: 26, low: 17, symbol: "cloud.sun.fill",
                condition: "多云",
                hourly: (0..<24).map { .init(date: now.addingTimeInterval(Double($0) * 3600),
                                             temperature: 23 - Double($0 % 8), symbol: "cloud.sun.fill") })
            if let url = cacheURL, let data = try? JSONEncoder().encode(report) {
                try? data.write(to: url, options: .atomic)
            }
            return report
        }
        #endif
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let (current, daily, hourly) = try await WeatherService.shared.weather(
                for: location, including: .current, .daily, .hourly)
            let now = Date()
            let today = daily.forecast.first { Calendar.current.isDate($0.date, inSameDayAs: now) }
                ?? daily.forecast.first
            let report = WeatherReport(
                fetchedAt: now,
                temperature: current.temperature.converted(to: .celsius).value,
                high: today?.highTemperature.converted(to: .celsius).value,
                low: today?.lowTemperature.converted(to: .celsius).value,
                symbol: current.symbolName,
                condition: current.condition.description,
                hourly: hourly.forecast
                    .filter { $0.date > now.addingTimeInterval(-3600) && $0.date < now.addingTimeInterval(86400) }
                    .map { .init(date: $0.date, temperature: $0.temperature.converted(to: .celsius).value,
                                 symbol: $0.symbolName) })
            if let url = cacheURL, let data = try? JSONEncoder().encode(report) {
                try? data.write(to: url, options: .atomic)
            }
            return report
        } catch {
            log.error("WeatherKit failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func disable() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    static func attribution() async -> WeatherAttribution? {
        guard let value = try? await WeatherService.shared.attribution else { return nil }
        return WeatherAttribution(lightMark: value.combinedMarkLightURL,
                                  darkMark: value.combinedMarkDarkURL,
                                  legalPage: value.legalPageURL)
    }

    /// 「23°」这种写法。摄氏/华氏看系统地区(不看应用内语言:英文界面不等于美制地区)。
    static func format(_ celsius: Double) -> String {
        // 只写「23°」不带 C/F(同系统天气);美制地区换成华氏度。
        let fahrenheit = Locale.current.measurementSystem == .us
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }
}
