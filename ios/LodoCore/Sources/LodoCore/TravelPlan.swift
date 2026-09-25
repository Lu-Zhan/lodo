import Foundation

/// 旅行的纯逻辑层:行程项的值类型 + 按天分组 + 价格汇总 + 喂给 AI 的摘要。
/// 和 `TaskData` ↔ `TaskItem` 一样,这里只吃值快照(`TravelEntry`),不碰
/// SwiftData 上下文,所以单测不用模拟器也能跑。

/// 行程项类型。存储值是 `MemoryItem.travelKindRaw` 里的字符串,别随便改。
public enum TravelItemKind: String, CaseIterable, Sendable {
    case flight
    case lodging
    case place

    public var titleKey: LK {
        switch self {
        case .flight: return .ios_core_travel_flight
        case .lodging: return .ios_core_travel_lodging
        case .place: return .ios_core_travel_place
        }
    }

    /// 喂给 AI 的固定中文名(prompt 不跟应用内语言走)。
    public var promptName: String {
        switch self {
        case .flight: return "航班"
        case .lodging: return "住宿"
        case .place: return "地点"
        }
    }

    public var systemImage: String {
        switch self {
        case .flight: return "airplane"
        case .lodging: return "bed.double"
        case .place: return "mappin.and.ellipse"
        }
    }
}

public struct TravelCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 一个行程项的值快照(由 `MemoryItem` 转出来)。
public struct TravelEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: TravelItemKind
    public let title: String
    public let summary: String
    public let start: Date?
    public let end: Date?
    public let price: Double?
    public let currency: String
    public let placeName: String?
    public let coordinate: TravelCoordinate?
    public let originName: String?
    public let originCoordinate: TravelCoordinate?
    public let code: String?
    /// 航班的补充信息(航站楼/登机口/座位/状态…);没导入过的航班、住宿、地点都是 nil。
    public let flight: FlightDetails?

    public init(id: UUID, kind: TravelItemKind, title: String, summary: String = "",
                start: Date? = nil, end: Date? = nil, price: Double? = nil,
                currency: String = "CNY", placeName: String? = nil,
                coordinate: TravelCoordinate? = nil, originName: String? = nil,
                originCoordinate: TravelCoordinate? = nil, code: String? = nil,
                flight: FlightDetails? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.start = start
        self.end = end
        self.price = price
        self.currency = currency
        self.placeName = placeName
        self.coordinate = coordinate
        self.originName = originName
        self.originCoordinate = originCoordinate
        self.code = code
        self.flight = flight
    }

    /// 还没排期:按天视图把它收进单独一组,而不是硬塞到第一天。
    public var isUnscheduled: Bool { start == nil }
}

extension TravelEntry {
    /// 从记忆条目转出来。不是旅行条目(没打标签或没有类型)时返回 nil。
    public init?(from item: MemoryItem) {
        guard item.isTravel, let kind = item.travelKind else { return nil }
        let coordinate = item.travelLatitude.flatMap { lat in
            item.travelLongitude.map { TravelCoordinate(latitude: lat, longitude: $0) }
        }
        let origin = item.travelOriginLatitude.flatMap { lat in
            item.travelOriginLongitude.map { TravelCoordinate(latitude: lat, longitude: $0) }
        }
        self.init(id: item.uuid, kind: kind, title: item.title, summary: item.summary,
                  start: item.travelStart, end: item.travelEnd, price: item.travelPrice,
                  currency: item.travelCurrencyOrDefault, placeName: item.travelPlaceName,
                  coordinate: coordinate, originName: item.travelOriginName,
                  originCoordinate: origin, code: item.travelCode,
                  flight: kind == .flight ? FlightDetails.decode(item.travelFlightData) : nil)
    }
}

/// 某一天的行程。
public struct TravelDay: Equatable, Sendable, Identifiable {
    public let date: Date
    public let entries: [TravelEntry]
    public var id: Date { date }

    public init(date: Date, entries: [TravelEntry]) {
        self.date = date
        self.entries = entries
    }
}

/// 住宿在某一天的位置(按天视图上那两枚标签)。
public struct LodgingNight: Equatable, Sendable {
    /// 今天入住。
    public let isCheckIn: Bool
    /// 今晚是最后一晚,明天退房离开。
    public let isLastNight: Bool

    public init(isCheckIn: Bool, isLastNight: Bool) {
        self.isCheckIn = isCheckIn
        self.isLastNight = isLastNight
    }
}

/// 一种币种的合计。
public struct TravelCostLine: Equatable, Sendable, Identifiable {
    public let currency: String
    public let amount: Double
    public var id: String { currency }

    public init(currency: String, amount: Double) {
        self.currency = currency
        self.amount = amount
    }
}

/// 折算成单一币种的总额,以及换不出汇率、没被算进去的那些币种。
/// `missingCurrencies` 非空时 UI 要如实说明,不能把它们默默吞掉当成 0。
public struct TravelTotal: Equatable, Sendable {
    public let amount: Double
    public let missingCurrencies: [String]

    public init(amount: Double, missingCurrencies: [String]) {
        self.amount = amount
        self.missingCurrencies = missingCurrencies
    }
}

public enum TravelPlan {

    // MARK: - 按天

    /// 把行程项铺到每一天。
    /// - 住宿按**住的每一晚**铺开(入住日到退房前一日),所以第 3 天也能看到"今晚住哪";
    ///   没填退房时间的就只出现在入住那天。
    /// - 航班/地点只落在开始时间那一天。
    /// - 没有开始时间的一律不进这里,走 `unscheduled(_:)`。
    /// - `days` 传 `TravelTrip.days`;落在行程区间之外的行程项(改签、提前到)
    ///   不会被丢掉,`outOfRange(_:days:)` 单独捞出来。
    public static func group(
        _ entries: [TravelEntry], into days: [Date], calendar: Calendar = .current
    ) -> [TravelDay] {
        days.map { day in
            let inDay = entries.filter { covers($0, day: day, calendar: calendar) }
            return TravelDay(date: day, entries: sortedForDay(inDay))
        }
    }

    /// 一天之内的排序:**住宿排在最上面**,其余按时间。
    /// 住宿的开始时间是入住时刻(通常傍晚),纯按时间排会掉到当天最底下,而
    /// "今晚住哪"是看这一天时首先要确认的一件事;中间几晚更是连时间都没有,
    /// 按 `sorted` 的规则会被扔到没时间那一档的最后。
    public static func sortedForDay(_ entries: [TravelEntry]) -> [TravelEntry] {
        sorted(entries.filter { $0.kind == .lodging })
            + sorted(entries.filter { $0.kind != .lodging })
    }

    /// 住宿在某一天的位置:是不是入住当晚、是不是最后一晚(第二天就退房走了)。
    /// 只住一晚时两个都为 true。不是住宿、或这一晚不住这儿时返回 nil。
    ///
    /// 最后一晚只在**填了退房时间**时才认得出来——没填退房的住宿本来就只出现在
    /// 入住那天,"明天就走"是猜的,不标。
    public static func lodgingNight(
        _ entry: TravelEntry, day: Date, calendar: Calendar = .current
    ) -> LodgingNight? {
        guard entry.kind == .lodging, let start = entry.start,
              covers(entry, day: day, calendar: calendar) else { return nil }
        let startDay = calendar.startOfDay(for: start)
        var isLastNight = false
        if let end = entry.end {
            let endDay = calendar.startOfDay(for: end)
            if endDay > startDay,
               let lastNight = calendar.date(byAdding: .day, value: -1, to: endDay) {
                isLastNight = lastNight == day
            }
        }
        return LodgingNight(isCheckIn: startDay == day, isLastNight: isLastNight)
    }

    /// 这一项是否属于某一天(day 是当天 0 点)。
    static func covers(_ entry: TravelEntry, day: Date, calendar: Calendar = .current) -> Bool {
        guard let start = entry.start else { return false }
        let startDay = calendar.startOfDay(for: start)
        guard entry.kind == .lodging, let end = entry.end else {
            return startDay == day
        }
        // 住宿算"住了几晚":退房当天早上就走了,不算那一天的住宿。
        let endDay = calendar.startOfDay(for: end)
        if endDay <= startDay { return startDay == day }
        return day >= startDay && day < endDay
    }

    /// 还没排期的行程项(想去但没定时间的地方、还没订的酒店)。
    public static func unscheduled(_ entries: [TravelEntry]) -> [TravelEntry] {
        sorted(entries.filter(\.isUnscheduled))
    }

    /// 有时间、但落在这趟旅行日期范围之外的行程项。改签/记错日期时不至于凭空消失。
    public static func outOfRange(
        _ entries: [TravelEntry], days: [Date], calendar: Calendar = .current
    ) -> [TravelEntry] {
        guard !days.isEmpty else { return sorted(entries.filter { !$0.isUnscheduled }) }
        let covered = Set(days)
        return sorted(entries.filter { entry in
            guard !entry.isUnscheduled else { return false }
            return !covered.contains { covers(entry, day: $0, calendar: calendar) }
        })
    }

    /// 排序:有时间的按时间升序在前,没时间的按标题排在后面。
    public static func sorted(_ entries: [TravelEntry]) -> [TravelEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.start, rhs.start) {
            case let (l?, r?): return l != r ? l < r : lhs.title < rhs.title
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
    }

    // MARK: - 价格

    /// 按币种合计。没填价格的项不参与;结果按金额降序,同额按币种码升序(稳定输出)。
    public static func costs(_ entries: [TravelEntry]) -> [TravelCostLine] {
        var totals: [String: Double] = [:]
        for entry in entries {
            guard let price = entry.price, price != 0 else { continue }
            totals[entry.currency, default: 0] += price
        }
        return totals
            .map { TravelCostLine(currency: $0.key, amount: $0.value) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.currency < $1.currency }
    }

    /// 某一类(航班/住宿/地点)的按币种合计。
    public static func costs(_ entries: [TravelEntry], kind: TravelItemKind) -> [TravelCostLine] {
        costs(entries.filter { $0.kind == kind })
    }

    /// 折算成单一币种的总额。`convert` 由调用方传(app 层的 `ExchangeRateStore`),
    /// 换不出来的币种不参与求和,而是原样报回去——宁可少算也不能拿错汇率糊弄。
    public static func total(
        _ entries: [TravelEntry], in target: String,
        convert: (Double, String, String) -> Double?
    ) -> TravelTotal {
        var sum = 0.0
        var missing: [String] = []
        for line in costs(entries) {
            if line.currency == target {
                sum += line.amount
            } else if let converted = convert(line.amount, line.currency, target) {
                sum += converted
            } else if !missing.contains(line.currency) {
                missing.append(line.currency)
            }
        }
        return TravelTotal(amount: sum, missingCurrencies: missing.sorted())
    }

    // MARK: - 喂给 AI

    /// 航班补充信息那一截:状态、航站楼/值机/登机口/座位、预计时刻、机型,有多少写多少。
    static func flightPromptLine(_ flight: FlightDetails, time: DateFormatter) -> String {
        var parts: [String] = []
        if let status = flight.status {
            parts.append("状态 " + LocalizedStrings.text(status.titleKey, language: .zhHans))
        }
        if let t = flight.departureTerminal { parts.append("出发航站楼 \(t)") }
        if let c = flight.checkInCounter { parts.append("值机柜台 \(c)") }
        if let g = flight.gate { parts.append("登机口 \(g)") }
        if let b = flight.boardingTime { parts.append("登机 \(time.string(from: b))") }
        if let e = flight.estimatedDeparture { parts.append("预计起飞 \(time.string(from: e))") }
        if let t = flight.arrivalTerminal { parts.append("到达航站楼 \(t)") }
        if let e = flight.estimatedArrival { parts.append("预计到达 \(time.string(from: e))") }
        if let b = flight.baggageBelt { parts.append("行李转盘 \(b)") }
        if let s = flight.seat { parts.append("座位 \(s)") }
        if let a = flight.aircraft { parts.append("机型 \(a)") }
        return parts.joined(separator: ",")
    }

    /// 格式化成给 AI 的一段中文文字(`read_trip` 工具的返回),固定中文、不跟应用内语言走。
    /// includeIDs:每行末尾带上 `[id:uuid]`。`read_trip` 喂给 AI 时开——模型要调整
    /// 行程(`edit_trip`)得原样引用行程项的 id;规划卡片存进对话历史的那份不开。
    public static func promptSummary(
        tripTitle: String, days: [Date], entries: [TravelEntry],
        includeIDs: Bool = false, calendar: Calendar = .current
    ) -> String {
        guard !entries.isEmpty else { return "「\(tripTitle)」还没有任何行程项。" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "M月d日"
        let time = DateFormatter()
        time.calendar = calendar
        time.dateFormat = "HH:mm"

        func line(_ entry: TravelEntry) -> String {
            var parts = ["\(entry.kind.promptName):\(entry.title)"]
            if let code = entry.code, !code.isEmpty { parts.append(code) }
            if let start = entry.start {
                var span = time.string(from: start)
                if let end = entry.end { span += "–" + time.string(from: end) }
                parts.append(span)
            }
            if let origin = entry.originName, !origin.isEmpty,
               let place = entry.placeName, !place.isEmpty {
                parts.append("\(origin) → \(place)")
            } else if let place = entry.placeName, !place.isEmpty {
                parts.append(place)
            }
            if let price = entry.price, price != 0 {
                parts.append("\(entry.currency) \(String(format: "%.2f", price))")
            }
            if let flight = entry.flight {
                let live = flightPromptLine(flight, time: time)
                if !live.isEmpty { parts.append(live) }
            }
            let id = includeIDs ? " [id:\(entry.id.uuidString)]" : ""
            return "  - " + parts.joined(separator: " · ") + id
        }

        var out = ["「\(tripTitle)」行程:"]
        for day in group(entries, into: days, calendar: calendar) where !day.entries.isEmpty {
            out.append(formatter.string(from: day.date))
            out.append(contentsOf: day.entries.map(line))
        }
        let extras = outOfRange(entries, days: days, calendar: calendar)
        if !extras.isEmpty {
            out.append("行程日期之外:")
            out.append(contentsOf: extras.map(line))
        }
        let pending = unscheduled(entries)
        if !pending.isEmpty {
            out.append("未排期:")
            out.append(contentsOf: pending.map(line))
        }
        let lines = costs(entries)
        if !lines.isEmpty {
            out.append("花费合计:" + lines
                .map { "\($0.currency) \(String(format: "%.2f", $0.amount))" }
                .joined(separator: "、"))
        }
        return out.joined(separator: "\n")
    }
}

/// `DeepSeekClient.parseTravelItems` 的返回:从订单文本里抽出来、**还没落库**的
/// 一个行程项。用户在确认页上过一眼才会变成真正的 `MemoryItem`。
public struct ParsedTravelItem: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let kind: TravelItemKind
    public let title: String
    public let code: String?
    public let start: Date?
    public let end: Date?
    public let placeName: String?
    public let originName: String?
    public let price: Double?
    public let currency: String?
    public let note: String
    /// 航班的补充信息;只有 kind == .flight 且文本/截图里真有这些内容时才非 nil。
    public let flight: FlightDetails?

    public init(kind: TravelItemKind, title: String, code: String? = nil,
                start: Date? = nil, end: Date? = nil, placeName: String? = nil,
                originName: String? = nil, price: Double? = nil,
                currency: String? = nil, note: String = "", flight: FlightDetails? = nil) {
        self.kind = kind
        self.title = title
        self.code = code
        self.start = start
        self.end = end
        self.placeName = placeName
        self.originName = originName
        self.price = price
        self.currency = currency
        self.note = note
        self.flight = flight
    }
}
