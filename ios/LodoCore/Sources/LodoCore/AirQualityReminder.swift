import Foundation

/// 空气质量提醒:用户设几个时间点(最多 4 个),每个时间点推一条「这会儿起三小时内
/// 预计最高 AQI + 两三条简短建议」。
///
/// **按 Open-Meteo 的逐小时预报提前排好**,而不是到点再去查:iOS 不让 app 准点在后台跑,
/// 所以每次取到新数据(打开 app、后台刷新)就用最新预报把接下来每个时间点的那一条重排一遍。
/// 预报没覆盖到的时间点不排(不编数字)。纯逻辑,单测 `AirQualityReminderTests`。

/// 一条简短建议。rawValue 只在 app 里映射成文案,不落盘。
public enum AirQualityTip: String, CaseIterable, Sendable {
    case goodForOutdoor
    case goodForMorningRun
    case openWindows
    case sensitiveCare
    case sensitiveMask
    case skipMorningRun
    case reduceOutdoorExercise
    case wearMask
    case closeWindows
    case stayIndoors
    case runPurifier

    /// 中文文案(app 里当 String Catalog 的 key 用)。
    public var text: String {
        switch self {
        case .goodForOutdoor: return "适合户外活动"
        case .goodForMorningRun: return "适合晨跑"
        case .openWindows: return "可以开窗通风"
        case .sensitiveCare: return "敏感人群留意身体"
        case .sensitiveMask: return "敏感人群出门戴口罩"
        case .skipMorningRun: return "不要晨跑"
        case .reduceOutdoorExercise: return "减少户外运动"
        case .wearMask: return "出门戴口罩"
        case .closeWindows: return "关好门窗"
        case .stayIndoors: return "尽量别出门"
        case .runPurifier: return "开空气净化器"
        }
    }
}

public enum AirQualityReminderPlan {
    /// 最多几个时间点(系统本地通知总共 64 条,纠缠链已占 48)。
    public static let maxTimes = 4
    /// 提醒里的 AQI 看这个时间点起多少小时内的最高值("出门这一阵会不会变差")。
    public static let lookAheadHours = 3

    public struct Slot: Equatable, Sendable {
        public let time: String
        public let fireDate: Date
        public let aqi: Int
        public let category: AQICategory
        public let tips: [AirQualityTip]
    }

    /// "07:00,18:30" → 去重、排序、只留合法的 HH:MM,最多 maxTimes 个。
    public static func parseTimes(_ raw: String) -> [String] {
        let valid = raw.split(separator: ",").compactMap { part -> String? in
            let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard pieces.count == 2, let h = Int(pieces[0]), let m = Int(pieces[1]),
                  (0..<24).contains(h), (0..<60).contains(m) else { return nil }
            return String(format: "%02d:%02d", h, m)
        }
        return Array(Array(Set(valid)).sorted().prefix(maxTimes))
    }

    public static func encode(_ times: [String]) -> String {
        parseTimes(times.joined(separator: ",")).joined(separator: ",")
    }

    /// 接下来每个时间点各一条(今天的已经过了就排明天)。
    /// - onlyWhenUnhealthy: 只在 AQI 超过「良」(>100)时才提醒。
    public static func slots(times: [String], hourly: [AirQualityReport.HourPoint], now: Date,
                             onlyWhenUnhealthy: Bool = false,
                             calendar: Calendar = .current) -> [Slot] {
        times.compactMap { time -> Slot? in
            let pieces = time.split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 2,
                  var fire = calendar.date(bySettingHour: pieces[0], minute: pieces[1], second: 0,
                                           of: now) else { return nil }
            if fire <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: fire) {
                fire = tomorrow
            }
            // 这个时间点所在的那一小时起,往后 lookAheadHours 小时。
            let windowStart = fire.addingTimeInterval(-3599)
            let windowEnd = fire.addingTimeInterval(Double(lookAheadHours) * 3600)
            let window = hourly.filter { $0.date >= windowStart && $0.date < windowEnd }
            guard let peak = window.map(\.aqi).max() else { return nil }
            if onlyWhenUnhealthy, peak <= 100 { return nil }
            let hour = calendar.component(.hour, from: fire)
            return Slot(time: time, fireDate: fire, aqi: peak, category: AQICategory(aqi: peak),
                        tips: tips(aqi: peak, hour: hour))
        }
        .sorted { $0.fireDate < $1.fireDate }
    }

    /// 两三条最要紧的建议。早上(5–10 点)的提醒把"跑步"换成晨跑的说法。
    public static func tips(aqi: Int, hour: Int) -> [AirQualityTip] {
        let morning = (5..<10).contains(hour)
        switch AQICategory(aqi: aqi) {
        case .good:
            return [morning ? .goodForMorningRun : .goodForOutdoor, .openWindows]
        case .moderate:
            return [morning ? .goodForMorningRun : .goodForOutdoor, .sensitiveCare]
        case .sensitive:
            return [morning ? .skipMorningRun : .reduceOutdoorExercise, .sensitiveMask]
        case .unhealthy:
            return [.wearMask, morning ? .skipMorningRun : .reduceOutdoorExercise, .closeWindows]
        case .veryUnhealthy, .hazardous:
            return [.stayIndoors, .wearMask, .runPurifier]
        }
    }
}
