import Foundation

/// 所在地今天的空气质量(美国 EPA 标准的 AQI),数据来自 Open-Meteo 的 Air Quality API
/// (`https://air-quality-api.open-meteo.com/v1/air-quality`,不要 key,底下是欧盟 CAMS
/// 的模型预报而不是监测站实测)。纯逻辑:拼请求、解析、分级,单测 `AirQualityTests`。
///
/// 隐私:发出去的只有**保留两位小数**的经纬度(约 1 公里),不带任何健康数据。

/// EPA 的六个等级。rawValue 写进小组件快照,别改。
public enum AQICategory: String, CaseIterable, Codable, Sendable {
    case good
    case moderate
    case sensitive
    case unhealthy
    case veryUnhealthy
    case hazardous

    public init(aqi: Int) {
        switch aqi {
        case ..<51: self = .good
        case ..<101: self = .moderate
        case ..<151: self = .sensitive
        case ..<201: self = .unhealthy
        case ..<301: self = .veryUnhealthy
        default: self = .hazardous
        }
    }

    /// 中文名(界面按应用内语言另行本地化,这里是 String Catalog 的 key)。
    public var title: String {
        switch self {
        case .good: return "优"
        case .moderate: return "良"
        case .sensitive: return "对敏感人群不健康"
        case .unhealthy: return "不健康"
        case .veryUnhealthy: return "非常不健康"
        case .hazardous: return "危险"
        }
    }

    /// 一句建议(同上,是 String Catalog 的 key)。
    public var advice: String {
        switch self {
        case .good: return "空气很好,适合户外活动。"
        case .moderate: return "空气尚可,极少数敏感的人减少长时间户外剧烈运动。"
        case .sensitive: return "儿童、老人和有呼吸道疾病的人减少户外剧烈运动。"
        case .unhealthy: return "减少户外活动,外出建议戴口罩。"
        case .veryUnhealthy: return "尽量待在室内,关好门窗。"
        case .hazardous: return "避免外出,开启空气净化。"
        }
    }

    /// EPA 规定的等级色(这是一套公认的标识色,不是 app 的状态色,所以不走 LodoColor)。
    public var colorHex: UInt32 {
        switch self {
        case .good: return 0x00E400
        case .moderate: return 0xFFFF00
        case .sensitive: return 0xFF7E00
        case .unhealthy: return 0xFF0000
        case .veryUnhealthy: return 0x8F3F97
        case .hazardous: return 0x7E0023
        }
    }
}

/// 参与美标 AQI 的污染物。rawValue 是 Open-Meteo 的字段后缀(`us_aqi_<raw>`)。
public enum AQIPollutant: String, CaseIterable, Codable, Sendable {
    case pm2_5
    case pm10
    case ozone = "ozone"
    case nitrogenDioxide = "nitrogen_dioxide"
    case sulphurDioxide = "sulphur_dioxide"
    case carbonMonoxide = "carbon_monoxide"

    /// 化学符号,各语言通用。
    public var symbol: String {
        switch self {
        case .pm2_5: return "PM2.5"
        case .pm10: return "PM10"
        case .ozone: return "O₃"
        case .nitrogenDioxide: return "NO₂"
        case .sulphurDioxide: return "SO₂"
        case .carbonMonoxide: return "CO"
        }
    }
}

public struct AirQualityReport: Codable, Equatable, Sendable {
    public struct HourPoint: Codable, Equatable, Sendable {
        public let date: Date
        public let aqi: Int
    }

    public var fetchedAt: Date
    /// 查询用的(已经取整过的)坐标,小组件拿它自己刷新。
    public var latitude: Double
    public var longitude: Double
    /// 当前的美标 AQI。
    public var aqi: Int
    /// 分项 AQI 最高的那一项(就是决定总 AQI 的那个)。
    public var dominant: AQIPollutant?
    /// 浓度,μg/m³。
    public var pm2_5: Double?
    public var pm10: Double?
    public var ozone: Double?
    public var nitrogenDioxide: Double?
    /// 逐小时的 AQI 预报,从今天(当地)0 点起两天。图表只画今天(`todayHourly`)。
    public var hourly: [HourPoint]
    /// 数据所在地的时区偏移(秒),判断"今天"用。
    public var utcOffsetSeconds: Int

    public var category: AQICategory { AQICategory(aqi: aqi) }

    /// 数据所在地"今天"那 24 小时(按接口给的时区偏移算,不按手机时区)。
    public func todayHourly(now: Date) -> [HourPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .current
        return hourly.filter { calendar.isDate($0.date, inSameDayAs: now) }
    }

    /// 今天剩下的时间里(含此刻)最高的那个小时。
    public func peak(after now: Date) -> HourPoint? {
        todayHourly(now: now).filter { $0.date.addingTimeInterval(3600) > now }.max { $0.aqi < $1.aqi }
    }

    /// 超过这么久就该重新拉(Open-Meteo 的数据是逐小时的)。
    public static let freshness: TimeInterval = 30 * 60

    public func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) < Self.freshness
    }
}

public enum OpenMeteoAirQuality {
    public static let endpoint = "https://air-quality-api.open-meteo.com/v1/air-quality"

    /// 经纬度保留两位小数(约 1 公里):查空气质量用不着更精确的位置。
    public static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    public static func url(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: endpoint)
        let subIndices = AQIPollutant.allCases.map { "us_aqi_\($0.rawValue)" }
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", rounded(latitude))),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", rounded(longitude))),
            URLQueryItem(name: "current", value: (["us_aqi", "pm2_5", "pm10", "ozone", "nitrogen_dioxide"]
                                                  + subIndices).joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "us_aqi"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // 两天:明早的提醒也要有预报可用(见 AirQualityReminderPlan)。
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        return components?.url
    }

    public enum ParseError: Error, Equatable {
        case malformed
        /// 接口自己报的错(`{"error": true, "reason": "…"}`)。
        case api(String)
        /// 这个位置/这个时刻没有 AQI。
        case noData
    }

    public static func parse(_ data: Data, now: Date = .now) throws -> AirQualityReport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.malformed
        }
        if root["error"] as? Bool == true {
            throw ParseError.api(root["reason"] as? String ?? "")
        }
        guard let current = root["current"] as? [String: Any] else { throw ParseError.malformed }
        func number(_ dict: [String: Any], _ key: String) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }

        // 分项最高的那一项决定总 AQI;总 AQI 缺了也能用分项补出来。
        let subs = AQIPollutant.allCases.compactMap { pollutant -> (AQIPollutant, Double)? in
            number(current, "us_aqi_\(pollutant.rawValue)").map { (pollutant, $0) }
        }
        let dominant = subs.max { $0.1 < $1.1 }
        guard let aqi = number(current, "us_aqi") ?? dominant?.1 else { throw ParseError.noData }

        var hourly: [AirQualityReport.HourPoint] = []
        if let block = root["hourly"] as? [String: Any],
           let times = block["time"] as? [Any], let values = block["us_aqi"] as? [Any] {
            for (time, value) in zip(times, values) {
                guard let seconds = (time as? NSNumber)?.doubleValue,
                      let value = (value as? NSNumber)?.doubleValue else { continue }
                hourly.append(.init(date: Date(timeIntervalSince1970: seconds),
                                    aqi: Int(value.rounded())))
            }
        }

        return AirQualityReport(
            fetchedAt: now,
            latitude: number(root, "latitude") ?? 0,
            longitude: number(root, "longitude") ?? 0,
            aqi: Int(aqi.rounded()),
            dominant: dominant?.0,
            pm2_5: number(current, "pm2_5"),
            pm10: number(current, "pm10"),
            ozone: number(current, "ozone"),
            nitrogenDioxide: number(current, "nitrogen_dioxide"),
            hourly: hourly,
            utcOffsetSeconds: (root["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0)
    }
}
