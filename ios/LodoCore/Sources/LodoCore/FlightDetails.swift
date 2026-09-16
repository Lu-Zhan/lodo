import Foundation

/// 航班行程项的补充信息:航站楼、值机柜台、登机口、座位、机型、航班状态……
///
/// **来源只有用户给的文本和截图**(订票邮件、行程单、登机牌、航司 App 的航班动态
/// 截图;截图在端上 OCR 成文字),由 `DeepSeekClient.parseTravelItems` 一并抽出来,
/// 不接任何航班数据 API。所以这里的每个字段都是"那张截图/那封邮件上写着的",
/// 不是实时数据——状态会过期,UI 要把 `updatedAt` 摆出来。
///
/// 整块 JSON 存在 `MemoryItem.travelFlightData` 上(字段多且全是可选的,拆成一堆列
/// 只会让模型和备份膨胀)。同一班飞机再导入一张新截图时走 `merged(with:)`:
/// 新截图上有的字段覆盖、没有的保留,这就是"动态更新"。
public struct FlightDetails: Equatable, Sendable, Codable {
    public var airline: String?
    /// 出发/到达机场的三字码(如 PEK/NRT),详情页头部大字显示用。
    public var departureCode: String?
    public var arrivalCode: String?
    public var departureTerminal: String?
    public var arrivalTerminal: String?
    public var checkInCounter: String?
    public var gate: String?
    public var boardingTime: Date?
    /// 截图上显示的变更后/预计时刻(延误、提前)。原计划时刻仍是行程项的 start/end,
    /// 两个都留着才看得出晚了多少。
    public var estimatedDeparture: Date?
    public var estimatedArrival: Date?
    public var seat: String?
    public var cabin: String?
    public var aircraft: String?
    public var baggageBelt: String?
    /// `FlightStatus` 的原始值;认不出的状态丢掉,不存乱码。
    public var statusRaw: String?
    /// 这份信息最后一次被导入/更新的时间(本机时间,不是截图上的时间)。
    public var updatedAt: Date?

    public init(airline: String? = nil, departureCode: String? = nil, arrivalCode: String? = nil,
                departureTerminal: String? = nil, arrivalTerminal: String? = nil,
                checkInCounter: String? = nil, gate: String? = nil, boardingTime: Date? = nil,
                estimatedDeparture: Date? = nil, estimatedArrival: Date? = nil,
                seat: String? = nil, cabin: String? = nil, aircraft: String? = nil,
                baggageBelt: String? = nil, status: FlightStatus? = nil, updatedAt: Date? = nil) {
        self.airline = airline
        self.departureCode = departureCode
        self.arrivalCode = arrivalCode
        self.departureTerminal = departureTerminal
        self.arrivalTerminal = arrivalTerminal
        self.checkInCounter = checkInCounter
        self.gate = gate
        self.boardingTime = boardingTime
        self.estimatedDeparture = estimatedDeparture
        self.estimatedArrival = estimatedArrival
        self.seat = seat
        self.cabin = cabin
        self.aircraft = aircraft
        self.baggageBelt = baggageBelt
        self.statusRaw = status?.rawValue
        self.updatedAt = updatedAt
    }

    public var status: FlightStatus? { statusRaw.flatMap(FlightStatus.init(rawValue:)) }

    /// 除 updatedAt 外一个字段都没有:AI 没从文本里读出任何补充信息。
    public var isEmpty: Bool {
        var copy = self
        copy.updatedAt = nil
        return copy == FlightDetails()
    }

    /// 相对原计划起飞晚了几分钟;没有预计时刻、或没晚点时为 nil。
    public func departureDelayMinutes(planned: Date?) -> Int? {
        Self.delay(planned: planned, estimated: estimatedDeparture)
    }

    public func arrivalDelayMinutes(planned: Date?) -> Int? {
        Self.delay(planned: planned, estimated: estimatedArrival)
    }

    private static func delay(planned: Date?, estimated: Date?) -> Int? {
        guard let planned, let estimated else { return nil }
        let minutes = Int((estimated.timeIntervalSince(planned) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// 用一份更新的信息(新导入的截图)合并:`newer` 里有的字段覆盖,没有的保留旧值。
    /// 不会因为新截图只拍到了登机口,就把之前登机牌上的座位号清掉。
    public func merged(with newer: FlightDetails) -> FlightDetails {
        FlightDetails(
            airline: newer.airline ?? airline,
            departureCode: newer.departureCode ?? departureCode,
            arrivalCode: newer.arrivalCode ?? arrivalCode,
            departureTerminal: newer.departureTerminal ?? departureTerminal,
            arrivalTerminal: newer.arrivalTerminal ?? arrivalTerminal,
            checkInCounter: newer.checkInCounter ?? checkInCounter,
            gate: newer.gate ?? gate,
            boardingTime: newer.boardingTime ?? boardingTime,
            estimatedDeparture: newer.estimatedDeparture ?? estimatedDeparture,
            estimatedArrival: newer.estimatedArrival ?? estimatedArrival,
            seat: newer.seat ?? seat,
            cabin: newer.cabin ?? cabin,
            aircraft: newer.aircraft ?? aircraft,
            baggageBelt: newer.baggageBelt ?? baggageBelt,
            status: newer.status ?? status,
            updatedAt: newer.updatedAt ?? updatedAt)
    }

    // MARK: - 编解码

    public static func encode(_ details: FlightDetails?) -> Data? {
        guard let details, !details.isEmpty else { return nil }
        return try? JSONEncoder().encode(details)
    }

    public static func decode(_ data: Data?) -> FlightDetails? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FlightDetails.self, from: data)
    }

    /// "CA 981"/"ca981" → "CA981",判断两次导入是不是同一班飞机用。
    public static func normalizedNumber(_ number: String?) -> String {
        (number ?? "").filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    }

    // MARK: - 解析(单测入口,不发请求)

    /// 从 AI 返回的行程项里那个 `"flight": {...}` 对象解析。时间格式同行程项
    /// ("yyyy-MM-dd HH:mm",由调用方传解析器);一个字段都读不出来时返回 nil。
    static func parse(_ raw: Any?, date: (String) -> Date?) -> FlightDetails? {
        guard let raw = raw as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            if let number = raw[key] as? NSNumber { return number.stringValue }
            guard let value = (raw[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let details = FlightDetails(
            airline: text("airline"),
            departureCode: text("departure_code")?.uppercased(),
            arrivalCode: text("arrival_code")?.uppercased(),
            departureTerminal: text("departure_terminal"),
            arrivalTerminal: text("arrival_terminal"),
            checkInCounter: text("check_in_counter"),
            gate: text("gate"),
            boardingTime: text("boarding_time").flatMap(date),
            estimatedDeparture: text("estimated_departure").flatMap(date),
            estimatedArrival: text("estimated_arrival").flatMap(date),
            seat: text("seat"),
            cabin: text("cabin"),
            aircraft: text("aircraft"),
            baggageBelt: text("baggage_belt"),
            status: text("status").flatMap { FlightStatus(rawValue: $0.lowercased()) })
        return details.isEmpty ? nil : details
    }
}

/// 截图/文本上看到的航班状态。原始值是 prompt 里约定给 AI 的英文词,别随便改。
public enum FlightStatus: String, CaseIterable, Sendable, Codable {
    case scheduled
    case checkIn = "check_in"
    case boarding
    case gateClosed = "gate_closed"
    case departed
    case delayed
    case arrived
    case canceled
    case diverted

    public var titleKey: LK {
        switch self {
        case .scheduled: return .ios_core_flight_status_scheduled
        case .checkIn: return .ios_core_flight_status_check_in
        case .boarding: return .ios_core_flight_status_boarding
        case .gateClosed: return .ios_core_flight_status_gate_closed
        case .departed: return .ios_core_flight_status_departed
        case .delayed: return .ios_core_flight_status_delayed
        case .arrived: return .ios_core_flight_status_arrived
        case .canceled: return .ios_core_flight_status_canceled
        case .diverted: return .ios_core_flight_status_diverted
        }
    }

    /// 粗分的语气,UI 据此选颜色。
    public enum Tone: Sendable { case neutral, active, warning, critical, done }

    public var tone: Tone {
        switch self {
        case .scheduled: return .neutral
        case .checkIn, .boarding, .departed: return .active
        case .gateClosed, .delayed: return .warning
        case .canceled, .diverted: return .critical
        case .arrived: return .done
        }
    }
}
