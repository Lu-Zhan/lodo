import Foundation

// 资产页「统计」:总资产趋势(过去 6 个月按填写日期 + 未来 6 个月估计)和各项组成。
// 纯逻辑,单测 `AssetTrendTests` 不碰 SwiftData。

/// 一项资产在某一天记下的金额(资产页每次保存金额时记一个点)。
public struct AssetValuePoint: Codable, Equatable, Sendable {
    public var date: Date
    public var value: Double?
    public var liability: Double?
    public var currency: String

    public init(date: Date, value: Double?, liability: Double?, currency: String) {
        self.date = date
        self.value = value
        self.liability = liability
        self.currency = currency
    }

    enum CodingKeys: String, CodingKey {
        case date = "d", value = "v", liability = "l", currency = "c"
    }

    func sameAmount(as other: AssetValuePoint) -> Bool {
        value == other.value && liability == other.liability && currency == other.currency
    }
}

public enum AssetHistory {
    /// 一项资产最多留多少个点(隔几个月更新一次的台账,几十年也用不完;防的是异常写入)。
    public static let limit = 240

    public static func decode(_ data: String) -> [AssetValuePoint] {
        guard !data.isEmpty, let raw = data.data(using: .utf8),
              let points = try? JSONDecoder().decode([AssetValuePoint].self, from: raw) else { return [] }
        return points.sorted { $0.date < $1.date }
    }

    public static func encode(_ points: [AssetValuePoint]) -> String {
        guard !points.isEmpty, let data = try? JSONEncoder().encode(points) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 追加一个点:同一天再保存一次覆盖当天那个点(一天改三次金额只算最后一次)。
    public static func appending(_ point: AssetValuePoint, to points: [AssetValuePoint],
                                 calendar: Calendar = .current) -> [AssetValuePoint] {
        var result = points.sorted { $0.date < $1.date }
        result.removeAll { calendar.isDate($0.date, inSameDayAs: point.date) }
        result.append(point)
        result.sort { $0.date < $1.date }
        if result.count > limit { result.removeFirst(result.count - limit) }
        return result
    }

    /// 画图用的历史:记下的点 + 当前金额。没有历史(老数据)时就是"更新时间那天是当前金额"
    /// 一个点;历史最后一个点和当前金额对不上(别的路径改过金额、老版本设备同步过来)时
    /// 在更新时间补一个当前金额的点——图上最新的值必须是页面上显示的那个数。
    public static func effective(_ points: [AssetValuePoint], current: AssetValuePoint) -> [AssetValuePoint] {
        var result = points.sorted { $0.date < $1.date }
        if let last = result.last, last.sameAmount(as: current) { return result }
        var point = current
        if let last = result.last, point.date < last.date { point.date = last.date }
        if let last = result.last, last.date == point.date { result.removeLast() }
        result.append(point)
        return result
    }
}

extension MemoryItem {
    /// 当前金额作为一个历史点(日期取更新时间)。
    public var currentAssetPoint: AssetValuePoint {
        AssetValuePoint(date: assetUpdatedAtOrCreated, value: assetValue,
                        liability: assetLiability, currency: assetCurrencyOrDefault)
    }

    /// 画图用的金额历史(见 `AssetHistory.effective`)。
    public var assetHistory: [AssetValuePoint] {
        AssetHistory.effective(AssetHistory.decode(assetHistoryData), current: currentAssetPoint)
    }

    /// 金额保存后调用:把当前金额记进历史。第一次记的时候先把改之前的那一笔
    /// (`before`,老数据没有历史)补进去,不然趋势图上看不出是从多少变过来的。
    public func recordAssetHistory(before: AssetValuePoint? = nil, at date: Date = .now) {
        var points = AssetHistory.decode(assetHistoryData)
        if points.isEmpty, let before, before.value != nil || before.liability != nil,
           before.date < date {
            points.append(before)
        }
        let point = AssetValuePoint(date: date, value: assetValue, liability: assetLiability,
                                    currency: assetCurrencyOrDefault)
        assetHistoryData = AssetHistory.encode(AssetHistory.appending(point, to: points))
    }
}

/// 总资产趋势:过去 `months` 个月按填写日期画实线,往后 `months` 个月按每月结余估计画虚线。
public struct AssetTrend: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let date: Date
        public let total: Double
    }

    /// 过去到现在(最后一个点是"现在")。
    public var history: [Point] = []
    /// 现在到 `months` 个月后(第一个点就是现在,和实线接上)。
    public var projection: [Point] = []
    /// 最近一次填写金额的日期(只看计入总数的资产)。
    public var lastUpdate: Date?
    /// 最近 `months` 个月一次都没更新过——图上是一条平线,提示该更新了。
    public var needsUpdate = false
    /// 换不出汇率、没有计入的币种。
    public var missingCurrencies: [String] = []

    public var isEmpty: Bool { history.isEmpty }

    public init() {}

    /// - Parameters:
    ///   - assets: 每项**计入总数**的资产的金额历史(`MemoryItem.assetHistory`)。
    ///   - monthlyNet: 每月结余(收入 − 固定支出含月供 − 月估计消费),已折算成 `currency`。
    ///     未来的估计 = 现在的总资产 + 每月结余 × 月数:收入进来、月供和消费出去。
    public static func build(assets: [[AssetValuePoint]], monthlyNet: Double, in currency: String,
                             now: Date, months: Int = 6, calendar: Calendar = .current,
                             convert: (Double, String, String) -> Double?) -> AssetTrend {
        var trend = AssetTrend()
        var missing: [String] = []
        let series = assets.map { $0.sorted { $0.date < $1.date } }.filter { !$0.isEmpty }
        guard !series.isEmpty else { return trend }

        func amount(_ point: AssetValuePoint) -> Double {
            guard let value = point.value else { return 0 }
            if point.currency == currency { return value }
            if let converted = convert(value, point.currency, currency) { return converted }
            if !missing.contains(point.currency) { missing.append(point.currency) }
            return 0
        }
        /// 某一刻的总资产:每项取那一刻之前最后一次记下的金额,那时还没记过的不算。
        func total(at date: Date) -> Double {
            series.reduce(0) { sum, points in
                guard let point = points.last(where: { $0.date <= date }) else { return sum }
                return sum + amount(point)
            }
        }

        let start = calendar.date(byAdding: .month, value: -months, to: now) ?? now
        let lastUpdate = series.compactMap(\.last?.date).max()
        trend.lastUpdate = lastUpdate
        trend.needsUpdate = (lastUpdate ?? now) < start

        var dates: [Date] = []
        if series.contains(where: { $0.first!.date <= start }) { dates.append(start) }
        // 同一天填了好几项(一次把整本台账核对一遍)只算一个点,取那天最后一次。
        var byDay: [Date: Date] = [:]
        for date in series.flatMap({ $0 }).map(\.date) where date > start && date < now {
            let day = calendar.startOfDay(for: date)
            byDay[day] = max(byDay[day] ?? date, date)
        }
        let today = calendar.startOfDay(for: now)
        dates += byDay.filter { $0.key != today }.values.sorted()
        dates.append(now)
        trend.history = dates.map { Point(date: $0, total: total(at: $0)) }

        let current = trend.history.last?.total ?? 0
        trend.projection = (0...months).compactMap { k in
            guard let date = calendar.date(byAdding: .month, value: k, to: now) else { return nil }
            return Point(date: date, total: current + monthlyNet * Double(k))
        }
        trend.missingCurrencies = missing.sorted()
        return trend
    }
}

extension FinancePlan {
    /// 组成图里的一块。
    public struct Slice: Equatable, Sendable, Identifiable {
        public let name: String
        public let amount: Double
        public var id: String { name }

        public init(name: String, amount: Double) {
            self.name = name
            self.amount = amount
        }
    }

    public struct Composition: Equatable, Sendable {
        public var slices: [Slice] = []
        public var missingCurrencies: [String] = []
        public var total: Double { slices.reduce(0) { $0 + $1.amount } }
    }

    /// 同名的合在一起、换算到 `currency`、按金额从大到小。≤ 0 的不进组成(饼图画不了负数)。
    public static func composition(_ items: [(name: String, amount: Double, currency: String)],
                                   in currency: String,
                                   convert: (Double, String, String) -> Double?) -> Composition {
        var result = Composition()
        var order: [String] = []
        var sums: [String: Double] = [:]
        var missing: [String] = []
        for item in items {
            let value = item.currency == currency ? item.amount : convert(item.amount, item.currency, currency)
            guard let value else {
                if !missing.contains(item.currency) { missing.append(item.currency) }
                continue
            }
            if sums[item.name] == nil { order.append(item.name) }
            sums[item.name, default: 0] += value
        }
        result.slices = order.compactMap { name in
            guard let amount = sums[name], amount > 0 else { return nil }
            return Slice(name: name, amount: amount)
        }
        .enumerated()
        .sorted { $0.element.amount != $1.element.amount ? $0.element.amount > $1.element.amount : $0.offset < $1.offset }
        .map(\.element)
        result.missingCurrencies = missing.sorted()
        return result
    }

    /// 收入组成用的每月金额:按周期折算,不定期的不算(同 `monthlyTotal`)。
    public static func monthlyAmount(_ entry: FinanceSnapshot) -> Double? {
        guard let amount = entry.amount, let factor = entry.effectiveCadence.monthlyFactor else { return nil }
        return amount * factor
    }
}
