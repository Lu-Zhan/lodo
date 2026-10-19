import Foundation

/// 体重秤报告导入的纯逻辑(单测 `WeightReportTests`):体脂秤 app 的截图 / PDF 经端上取字、
/// AI 整理出一组测量,这里负责把 AI 给的 JSON 变成可信的数字——单位换算、限幅、日期、去重。
///
/// 和体检报告不同,这条路径**有确认页**:一次测量就是趋势图上的一个点,日期或单位认错了
/// 会悄悄把整条曲线带歪,所以先列出来让用户核对、勾选,再落库(`WeightReportStore`)。

/// 一次测量(一台秤一次称重)。数值都已经换算成公斤 / 千卡,超出合理范围的那一项为 nil。
public struct ParsedWeightMeasurement: Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// 称重时间;截图上看不出日期时为 nil(确认页要用户自己定)。
    public var date: Date?
    /// 截图上只有日期、没有几点几分。
    public var dateOnly: Bool
    public var weightKg: Double?
    public var bodyFatPercent: Double?
    public var muscleMassKg: Double?
    /// 内脏脂肪等级(无单位的等级,不是百分比也不是面积)。
    public var visceralFatLevel: Double?
    /// 基础代谢,千卡/天。
    public var basalMetabolicKcal: Double?
    public var bodyWaterPercent: Double?
    public var boneMassKg: Double?

    public init(id: UUID = UUID(), date: Date? = nil, dateOnly: Bool = false,
                weightKg: Double? = nil, bodyFatPercent: Double? = nil, muscleMassKg: Double? = nil,
                visceralFatLevel: Double? = nil, basalMetabolicKcal: Double? = nil,
                bodyWaterPercent: Double? = nil, boneMassKg: Double? = nil) {
        self.id = id
        self.date = date
        self.dateOnly = dateOnly
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.muscleMassKg = muscleMassKg
        self.visceralFatLevel = visceralFatLevel
        self.basalMetabolicKcal = basalMetabolicKcal
        self.bodyWaterPercent = bodyWaterPercent
        self.boneMassKg = boneMassKg
    }

    /// 至少有一项读数。
    public var hasValue: Bool {
        weightKg != nil || bodyFatPercent != nil || muscleMassKg != nil || visceralFatLevel != nil
            || basalMetabolicKcal != nil || bodyWaterPercent != nil || boneMassKg != nil
    }
}

public struct ParsedWeightReport: Equatable, Sendable {
    /// 报告名(如「小米体脂秤 10 月记录」);没给就由 app 按日期起名。
    public var title: String
    /// 秤 / app 的名字,没写为空。
    public var device: String
    public var measurements: [ParsedWeightMeasurement]
    /// 有读数因为单位不明或超出范围被丢掉了(确认页如实说一声)。
    public var droppedValues: Int

    public init(title: String = "", device: String = "", measurements: [ParsedWeightMeasurement] = [],
                droppedValues: Int = 0) {
        self.title = title
        self.device = device
        self.measurements = measurements
        self.droppedValues = droppedValues
    }
}

public enum WeightReport {
    // MARK: - 合理范围(超出 = 认错了,丢掉这一项,不截成边界值)

    public static let weightRange: ClosedRange<Double> = 1...500
    public static let bodyFatRange: ClosedRange<Double> = 1...79
    public static let visceralRange: ClosedRange<Double> = 1...60
    public static let basalRange: ClosedRange<Double> = 300...10_000
    public static let waterRange: ClosedRange<Double> = 1...99
    public static let boneRange: ClosedRange<Double> = 0.1...20
    public static let muscleRange: ClosedRange<Double> = 1...300

    /// 带时分的测量最多比"现在"晚这么多(两台设备的时钟误差),再晚就当认错了。
    public static let futureSlack: TimeInterval = 5 * 60

    /// 每斤 / 每磅多少公斤。
    private static let kgPerJin = 0.5
    private static let kgPerPound = 0.45359237
    private static let kJPerKcal = 4.184

    // MARK: - 解析

    /// 从 AI 返回的 payload 解析(单测入口,不发请求)。缺 `measurements` 报格式错误;
    /// 单条测量里认不出的那几项丢掉、其余照留,一项读数都没有的那条整条丢掉。
    /// `now` 用来挡住"未来的日期"(OCR 把 2025 认成 2052 这类)。
    public static func parse(_ payload: [String: Any], now: Date = Date(),
                             calendar: Calendar = .current) throws -> ParsedWeightReport {
        guard let raw = payload["measurements"] as? [[String: Any]] else {
            throw DeepSeekError.parse("返回格式异常:缺少 measurements")
        }
        var dropped = 0
        var measurements: [ParsedWeightMeasurement] = []
        for item in raw {
            // 质量类(体重/肌肉量/骨量)的单位:截图上写什么 AI 就照填什么,换算在这里做。
            // 每项各有自己的单位(`weight_unit`/`muscle_unit`/`bone_unit`——体重用斤、肌肉量
            // 用公斤的 app 是有的),没给再退回整条的 `mass_unit`,都没写按公斤;写了认不出的
            // 单位,那一项不认(宁可让用户手填)。
            func mass(_ key: String, _ range: ClosedRange<Double>) -> Double? {
                guard let value = number(item[key]) else { return nil }
                let factor = massUnitFactor(item["\(key)_unit"] ?? item["mass_unit"])
                guard let factor, let kg = rounded(value * factor), range.contains(kg) else {
                    dropped += 1
                    return nil
                }
                return kg
            }
            func plain(_ key: String, _ range: ClosedRange<Double>) -> Double? {
                guard let value = number(item[key]) else { return nil }
                guard let value = rounded(value), range.contains(value) else {
                    dropped += 1
                    return nil
                }
                return value
            }
            var m = ParsedWeightMeasurement()
            m.weightKg = mass("weight", weightRange)
            m.bodyFatPercent = plain("body_fat", bodyFatRange)
            m.muscleMassKg = mass("muscle", muscleRange)
            m.visceralFatLevel = plain("visceral_fat", visceralRange)
            m.bodyWaterPercent = plain("water", waterRange)
            m.boneMassKg = mass("bone", boneRange)
            if let value = number(item["bmr"]) {
                let unit = (item["bmr_unit"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
                let kcal: Double? = switch unit {
                case "", "kcal", "千卡", "大卡", "卡路里": value
                case "kj", "千焦": value / kJPerKcal
                default: nil
                }
                if let kcal, let r = kcal.isFinite ? kcal.rounded() : nil, basalRange.contains(r) {
                    m.basalMetabolicKcal = r
                } else {
                    dropped += 1
                }
            }
            // 肌肉量、骨量是体重的一部分,比体重还大一定是认错了。
            if let weight = m.weightKg {
                if let muscle = m.muscleMassKg, muscle >= weight { m.muscleMassKg = nil; dropped += 1 }
                if let bone = m.boneMassKg, bone >= weight { m.boneMassKg = nil; dropped += 1 }
            }
            if let time = item["time"] as? String, let parsed = parseDate(time, calendar: calendar) {
                // 未来的日期多半是 OCR 认错了年份/日子:当作没看到日期,让用户自己定。
                // 只有日期的按自然日比(不能晚于今天;今天的取中午和现在较早的那个,不存一个
                // 还没到的时刻),带时分的不能晚于现在(留几分钟给两台设备的时钟误差)。
                if parsed.dateOnly {
                    if calendar.startOfDay(for: parsed.date) <= calendar.startOfDay(for: now) {
                        m.date = min(parsed.date, now)
                        m.dateOnly = true
                    }
                } else if parsed.date <= now.addingTimeInterval(futureSlack) {
                    m.date = parsed.date
                }
            }
            if m.hasValue { measurements.append(m) }
        }
        func text(_ key: String) -> String {
            (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ParsedWeightReport(title: text("title"), device: text("device"),
                                  measurements: measurements.sorted {
                                      ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture)
                                  },
                                  droppedValues: dropped)
    }

    /// 数字:只认真正的数(JSON 数字或纯 ASCII 数字串)。布尔值、范围串("60-65")、
    /// 带单位的串("60kg")、NaN/无穷一律不认——那些都说明模型没按格式给,猜一个数比
    /// 留空更糟。
    public static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            // JSON 的 true/false 也是 NSNumber,`as? Double` 会把 true 读成 1。
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let double = value.doubleValue
            return double.isFinite ? double : nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }),
                  trimmed.filter({ $0 == "." }).count <= 1,
                  let double = Double(trimmed), double.isFinite else { return nil }
            return double
        default:
            return nil
        }
    }

    /// 质量单位 → 换算成公斤要乘的数;认不出返回 nil。
    static func massUnitFactor(_ raw: Any?) -> Double? {
        guard let unit = (raw as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
              !unit.isEmpty else { return 1 }
        switch unit {
        case "kg", "公斤", "千克": return 1
        case "斤", "jin": return kgPerJin
        case "lb", "lbs", "磅": return kgPerPound
        default: return nil
        }
    }

    /// 保留一位小数(秤本来就只显示到 0.1)。
    private static func rounded(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }

    /// "YYYY-MM-DD HH:MM" 或 "YYYY-MM-DD"。只有日期时取当天中午——不编一个"几点称的",
    /// 取中午只是为了跨时区归日时不掉到前一天/后一天。
    static func parseDate(_ text: String, calendar: Calendar) -> (date: Date, dateOnly: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "T" })
        let ymd = parts.first.map { $0.split(separator: "-").compactMap { Int($0) } } ?? []
        guard ymd.count == 3, (1...12).contains(ymd[1]), (1...31).contains(ymd[2]) else { return nil }
        var components = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2])
        var dateOnly = true
        if parts.count > 1 {
            let hm = parts[1].split(separator: ":").compactMap { Int($0) }
            if hm.count >= 2, (0...23).contains(hm[0]), (0...59).contains(hm[1]) {
                components.hour = hm[0]
                components.minute = hm[1]
                dateOnly = false
            }
        }
        if dateOnly { components.hour = 12 }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == ymd[2] else { return nil }   // 挡住 2 月 30 日
        return (date, dateOnly)
    }

    // MARK: - 去重

    /// 这次测量是不是已经记过了:同一天、体重相差不到 0.05 公斤(没有体重时比体脂率)。
    /// 只用来**默认不勾选**,用户在确认页仍然可以勾上——同一天称两次一样的数是可能的。
    public static func isDuplicate(_ measurement: ParsedWeightMeasurement, existing: [WeightEntry],
                                   calendar: Calendar = .current) -> Bool {
        guard let date = measurement.date else { return false }
        return existing.contains { entry in
            guard !entry.fromHealth, calendar.isDate(entry.date, inSameDayAs: date) else { return false }
            if let weight = measurement.weightKg {
                guard let other = entry.weightKg else { return false }
                return abs(weight - other) < 0.05
            }
            if let fat = measurement.bodyFatPercent, let other = entry.bodyFatPercent {
                return abs(fat - other) < 0.05
            }
            return false
        }
    }
}
