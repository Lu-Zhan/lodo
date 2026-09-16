import Foundation

/// 航班时刻查询:接 AeroDataBox(https://aerodatabox.com),按"航班号 + 日期"查
/// 起降时间与机场(含坐标)。key 存钥匙串,复用 `KeychainHelper` 按"服务商"分存的
/// 机制,把 AeroDataBox 当一个服务商——和 Tavily 同一个路子,不单独加一套存取逻辑。
///
/// **这是可选增强,不是必需路径**:没配 key 时表单里那颗「查」根本不出现,航班信息
/// 照旧手填或走「从订单导入」。查不到、解析不了也只是提示一句,绝不写错数据进去
/// ——照着错的起飞时间去机场,比没有这个功能糟得多。
///
/// ⚠️ 响应字段是按 AeroDataBox 公开文档的形状写的,**没有在真实响应上验证过**
/// (实现时这台机器解析不了 doc.aerodatabox.com)。`parseFlights` 是纯函数、有单测,
/// 拿到真实响应后照着调这一个函数即可,调用方不用动。字段拿不到时宁可留 nil,
/// 不猜。
public enum FlightLookupClient {

    /// 查询结果:一个航段的起降两端。
    public struct Flight: Equatable, Sendable {
        public let number: String
        public let airlineName: String?
        public let departure: Endpoint
        public let arrival: Endpoint

        public init(number: String, airlineName: String?, departure: Endpoint, arrival: Endpoint) {
            self.number = number
            self.airlineName = airlineName
            self.departure = departure
            self.arrival = arrival
        }
    }

    /// 起点或终点。所有字段都可能缺——API 对小机场/包机的覆盖不全,缺了就留空,
    /// 让用户自己补,不要编。
    public struct Endpoint: Equatable, Sendable {
        public let airportName: String?
        public let iata: String?
        public let scheduledTime: Date?
        public let latitude: Double?
        public let longitude: Double?
        public let terminal: String?

        public init(airportName: String? = nil, iata: String? = nil, scheduledTime: Date? = nil,
                    latitude: Double? = nil, longitude: Double? = nil, terminal: String? = nil) {
            self.airportName = airportName
            self.iata = iata
            self.scheduledTime = scheduledTime
            self.latitude = latitude
            self.longitude = longitude
            self.terminal = terminal
        }

        /// 填进行程项地点栏的显示名:"东京成田 (NRT)";没有机场名时退回 IATA 码。
        public var displayName: String? {
            switch (airportName, iata) {
            case let (name?, code?): return "\(name) (\(code))"
            case let (name?, nil): return name
            case let (nil, code?): return code
            default: return nil
            }
        }

        public var hasCoordinate: Bool { latitude != nil && longitude != nil }
    }

    /// key 从哪来。免费额度(Basic 600 units/月)走 RapidAPI;官方直连是另一套
    /// 域名和鉴权头,两者的响应体一致,所以只在构造请求这一处分叉。
    public enum Host: String, CaseIterable, Sendable {
        case rapidAPI
        case direct

        var baseURL: String {
            switch self {
            case .rapidAPI: return "https://aerodatabox.p.rapidapi.com"
            case .direct: return "https://aerodatabox.com/api"
            }
        }

        func apply(to request: inout URLRequest, key: String) {
            switch self {
            case .rapidAPI:
                request.setValue(key, forHTTPHeaderField: "x-rapidapi-key")
                request.setValue("aerodatabox.p.rapidapi.com", forHTTPHeaderField: "x-rapidapi-host")
            case .direct:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
        }
    }

    public enum FlightLookupError: LocalizedError {
        case noKey
        case notFound
        case api(String)

        public var errorDescription: String? {
            let language = AppSettings.language
            switch self {
            case .noKey:
                return LocalizedStrings.text(.ios_core_flight_api_key_not_configured, language: language)
            case .notFound:
                return LocalizedStrings.text(.ios_core_flight_not_found, language: language)
            case .api(let m):
                return LocalizedStrings.text(.ios_core_flight_lookup_failed, language: language)
                    + LocalizedStrings.translate(m, language: language)
            }
        }
    }

    public static let providerName = "AeroDataBox"

    /// 已配置 key;表单里那颗「查」按钮据此决定要不要出现。
    public static var isConfigured: Bool {
        KeychainHelper.apiKey(for: providerName) != nil
    }

    /// 查某个航班号在某一天的时刻。同一航班号一天可能有多班(经停/多段),
    /// 全部返回,由调用方决定怎么挑。
    public static func lookup(
        number: String, date: Date, host: Host = .rapidAPI
    ) async throws -> [Flight] {
        guard let apiKey = KeychainHelper.apiKey(for: providerName) else {
            throw FlightLookupError.noKey
        }
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(host.baseURL)/flights/number/\(encoded)/\(dayFormatter.string(from: date))")
        else {
            throw FlightLookupError.notFound
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        host.apply(to: &request, key: apiKey)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 这个日期没有这班飞机时 API 返回 404,不算出错,就是"没查到"。
        if status == 404 { throw FlightLookupError.notFound }
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FlightLookupError.api("HTTP \(status) \(body.prefix(200))")
        }
        let flights = try parseFlights(try JSONSerialization.jsonObject(with: data))
        guard !flights.isEmpty else { throw FlightLookupError.notFound }
        return flights
    }

    // MARK: - 解析(单测入口,不发请求)

    /// 从响应 JSON 解析航班。顶层既接受数组(flights/number 的常规返回),
    /// 也接受包一层 `{"flights": [...]}` 的形状。单条缺关键字段就跳过那条,
    /// 不让整次查询白费。
    static func parseFlights(_ payload: Any) throws -> [Flight] {
        let items: [[String: Any]]
        if let array = payload as? [[String: Any]] {
            items = array
        } else if let root = payload as? [String: Any],
                  let array = root["flights"] as? [[String: Any]] {
            items = array
        } else if let root = payload as? [String: Any] {
            items = [root]
        } else {
            throw FlightLookupError.api("返回格式异常")
        }
        return items.compactMap(parseFlight)
    }

    private static func parseFlight(_ raw: [String: Any]) -> Flight? {
        // 历史上 FIDS 那组接口把起降包在 movement 里,flights/number 是
        // departure/arrival 两个对象。两种都认,省得换个接口就解析不出来。
        let departureRaw = (raw["departure"] as? [String: Any])
            ?? (raw["movement"] as? [String: Any])
        let arrivalRaw = raw["arrival"] as? [String: Any]
        guard let number = (raw["number"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty else {
            return nil
        }
        let airline = (raw["airline"] as? [String: Any])?["name"] as? String
        return Flight(
            number: number,
            airlineName: airline,
            departure: parseEndpoint(departureRaw),
            arrival: parseEndpoint(arrivalRaw))
    }

    private static func parseEndpoint(_ raw: [String: Any]?) -> Endpoint {
        guard let raw else { return Endpoint() }
        let airport = raw["airport"] as? [String: Any]
        let location = airport?["location"] as? [String: Any]
        return Endpoint(
            airportName: (airport?["name"] as? String) ?? (airport?["shortName"] as? String)
                ?? (airport?["municipalityName"] as? String),
            iata: airport?["iata"] as? String,
            // 优先用改签后的实际时刻,没有才用计划时刻——用户要的是"我几点到机场"。
            scheduledTime: parseTime(raw["revisedTime"]) ?? parseTime(raw["scheduledTime"]),
            latitude: location?["lat"] as? Double,
            longitude: location?["lon"] as? Double,
            terminal: raw["terminal"] as? String)
    }

    /// 时间对象形如 {"utc": "2026-07-08 09:00Z", "local": "2026-07-08 17:00+08:00"}。
    /// **优先取 local**:行程里"几点起飞"说的就是当地时间,取 utc 再按手机时区显示
    /// 会在跨时区旅行时差出好几个小时。
    static func parseTime(_ raw: Any?) -> Date? {
        guard let object = raw as? [String: Any] else { return nil }
        for key in ["local", "utc"] {
            guard let text = object[key] as? String else { continue }
            if let date = parseTimestamp(text) { return date }
        }
        return nil
    }

    /// AeroDataBox 的时间戳是 "yyyy-MM-dd HH:mmZ" / "yyyy-MM-dd HH:mm+08:00" 这种
    /// 空格分隔的形状,不是标准 ISO8601(那个要求 T 分隔),所以自己列格式试。
    static func parseTimestamp(_ text: String) -> Date? {
        for formatter in timestampFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let timestampFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mmZZZZZ", "yyyy-MM-dd HH:mm:ssZZZZZ",
         "yyyy-MM-dd'T'HH:mmZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
