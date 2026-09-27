import Foundation

/// 旅行的一个目的地(城市 + 国家,都是用户手填的文字,可以只填一个)。
///
/// 一次旅行可以有多个目的地(「北海道 · 日本」+「上海 · 中国」)。**第一个就是
/// `TravelTrip.city`/`country` 那两列**,第二个起存进 `TravelTrip.extraDestinations`
/// (JSON 串)——这样只认第一个目的地的老代码、老备份、AI 的 `plan_trip`(只给一对
/// city/country)照旧可用,多出来的目的地是加法。
public struct TripDestination: Codable, Hashable, Sendable {
    public var city: String
    public var country: String

    public init(city: String = "", country: String = "") {
        self.city = city
        self.country = country
    }

    public var trimmed: TripDestination {
        TripDestination(city: city.trimmingCharacters(in: .whitespacesAndNewlines),
                        country: country.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var isEmpty: Bool { trimmed.city.isEmpty && trimmed.country.isEmpty }

    /// "北海道 · 日本";只填了一个就只显示那一个。
    public var displayText: String {
        let t = trimmed
        return [t.city, t.country].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 地名搜索消歧用的词("北海道 日本",按空格拼,中点拼进搜索词只会添乱)。
    public var searchHint: String? {
        let t = trimmed
        let parts = [t.city, t.country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 这个目的地的国家/地区 ISO 码(国家栏 → 城市栏),认不出返回 nil。
    public var regionCode: String? {
        PlaceRegion.isoCode(in: [country, city])
    }

    // MARK: - 存储

    /// 第二个起的目的地编码成 JSON 串存进 `TravelTrip.extraDestinations`。空的丢掉,
    /// 一个都不剩时存空串(不是 "[]"),和从没设过的旅行一样。
    public static func encode(_ destinations: [TripDestination]) -> String {
        let kept = destinations.map(\.trimmed).filter { !$0.isEmpty }
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解码失败(被别的版本写坏了)按没有处理,不抛错打断页面。
    public static func decode(_ text: String) -> [TripDestination] {
        guard !text.isEmpty,
              let list = try? JSONDecoder().decode([TripDestination].self, from: Data(text.utf8))
        else { return [] }
        return list.map(\.trimmed).filter { !$0.isEmpty }
    }

    /// 一整串目的地拆回 (第一个, 其余的 JSON)。第一个空着时后面的往前挪——
    /// 删掉第一个目的地不能让第二个变成"只存在于附加列表里"的孤儿。
    public static func split(_ destinations: [TripDestination])
        -> (primary: TripDestination, extras: String) {
        let kept = destinations.map(\.trimmed).filter { !$0.isEmpty }
        guard let first = kept.first else { return (TripDestination(), "") }
        return (first, encode(Array(kept.dropFirst())))
    }

    // MARK: - 行程项归属

    /// 一条行程项该先按哪个目的地去查地名:返回目的地下标的顺序。
    ///
    /// 判据只有**行程项自己的文字里点名了哪个目的地**(标题/地点名/备注里出现了
    /// 城市名或国家名,如「上海外滩」「札幌 · 二条市场」),点名了的排前面;
    /// 都没点名就保持原顺序,由调用方再按同一天别的地点离哪边近来排。
    public static func preferredOrder(_ destinations: [TripDestination], text: String) -> [Int] {
        let indices = Array(destinations.indices)
        return indices.filter { mentioned(destinations[$0], in: text) }
            + indices.filter { !mentioned(destinations[$0], in: text) }
    }

    /// 文字里点名了这个目的地(城市名或国家名,至少两个字,免得单字误中)。
    public static func mentioned(_ destination: TripDestination, in text: String) -> Bool {
        let haystack = text.lowercased()
        return [destination.trimmed.city, destination.trimmed.country]
            .filter { $0.count >= 2 }
            .contains { haystack.contains($0.lowercased()) }
    }
}

extension TravelTrip {
    /// 全部目的地(第一个 = city/country 那两列),空的不算。
    public var destinations: [TripDestination] {
        get {
            let primary = TripDestination(city: city, country: country).trimmed
            return (primary.isEmpty ? [] : [primary]) + TripDestination.decode(extraDestinations)
        }
        set {
            let (primary, extras) = TripDestination.split(newValue)
            city = primary.city
            country = primary.country
            extraDestinations = extras
        }
    }

    /// 城市、国家一个都没填(那时地名搜索没有判据,见 `TravelStore.geocodeContext`)。
    public var lacksLocation: Bool { destinations.isEmpty }

    /// 目的地变了没有(`onChange` 用)。
    public var destinationsKey: String { city + "|" + country + "|" + extraDestinations }
}
