import Foundation

/// OpenStreetMap Nominatim 地名查询的纯逻辑部分(请求地址、解析、名字校验),
/// `OSMGeocodeTests` 离线单测;真正发请求在 app 层 `PlaceGeocoder`。
///
/// 为什么要它:苹果的地名服务在国内网络上**只给中国数据**——`MKLocalSearch`、
/// `CLGeocoder`、`MKGeocodingRequest` 三条路实测全是如此(「浅草」→ 沈阳的 Qiancao,
/// 「东京 日本」→ 广西平南的 Tokyo,带区域偏置直接 GEOError -8),国外旅行的地点
/// 一个都定位不到。Nominatim 在同样的网络下能正常返回日本等地的结果,并且
/// 支持按国家筛(`countrycodes`),正好接上我们"先验国家再用"的判据。
///
/// Nominatim 是模糊匹配,会把「新宿王子酒店」匹配成埼玉的「喜多屋酒店倉庫」
/// (只重了"酒店"两个字),所以结果还要过一道**名字校验**(`nameScore`)。
public enum OSMGeocode {
    public struct Place: Equatable, Sendable, Identifiable {
        public let id: String
        /// 显示用的名字(按请求语言;没有就取别的名字)。
        public let name: String
        /// 完整地址(Nominatim 的 display_name),手动搜索列表的第二行。
        public let displayName: String
        public let latitude: Double
        public let longitude: Double
        /// ISO 3166-1 alpha-2,大写。
        public let countryCode: String?
        /// 各语言名字、别名、官方名(校验用)。
        public let names: [String]
        /// Nominatim 的 addresstype:city / town / suburb / amenity / railway …
        public let addressType: String
    }

    /// 同一趟请求里名字对上的最低分(查询词里的字有多少出现在结果名字里)。
    public static let minimumNameScore = 0.6

    /// 城市级的 addresstype:验城市锚点时只认这些(同 `PlaceGeocoder.verifiedAnchor`
    /// 只认行政区划、不认店名的口径)。
    public static let areaTypes: Set<String> = [
        "city", "town", "village", "municipality", "county", "state", "province",
        "region", "city_district", "district", "borough", "prefecture",
    ]

    /// 大陆/港澳台互认(同 `PlaceRegion.matches`),查询时也一起带上。
    public static func countryCodesParam(for region: String?) -> String? {
        guard let region = region?.uppercased(), !region.isEmpty else { return nil }
        if ["CN", "HK", "MO", "TW"].contains(region) { return "cn,hk,mo,tw" }
        return region.lowercased()
    }

    /// 搜索地址。有锚点时给一个 ±`radius` 度的 viewbox 做排序偏置(不硬性限定,
    /// 一趟旅行跨两个城市是常事)。
    public static func searchURL(query: String, region: String?,
                                 anchor: TravelCoordinate? = nil, radius: Double = 1.0,
                                 language: String = "zh", limit: Int = 8) -> URL? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "namedetails", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "accept-language", value: language),
        ]
        if let codes = countryCodesParam(for: region) {
            items.append(URLQueryItem(name: "countrycodes", value: codes))
        }
        if let anchor {
            let box = [anchor.longitude - radius, anchor.latitude + radius,
                       anchor.longitude + radius, anchor.latitude - radius]
                .map { String(format: "%.4f", $0) }.joined(separator: ",")
            items.append(URLQueryItem(name: "viewbox", value: box))
        }
        components?.queryItems = items
        return components?.url
    }

    public static func parse(_ data: Data) -> [Place] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { raw in
            guard let lat = Double(raw["lat"] as? String ?? ""),
                  let lon = Double(raw["lon"] as? String ?? "") else { return nil }
            let address = raw["address"] as? [String: Any]
            var names: [String] = []
            if let name = raw["name"] as? String, !name.isEmpty { names.append(name) }
            if let details = raw["namedetails"] as? [String: Any] {
                names += details.values.compactMap { $0 as? String }.filter { !$0.isEmpty }
            }
            let display = raw["display_name"] as? String ?? ""
            let osmID = "\(raw["osm_type"] as? String ?? "")\(raw["osm_id"].map { "\($0)" } ?? "\(lat),\(lon)")"
            return Place(id: osmID,
                         name: names.first ?? display.components(separatedBy: ",").first ?? "",
                         displayName: display,
                         latitude: lat, longitude: lon,
                         countryCode: (address?["country_code"] as? String)?.uppercased(),
                         names: names,
                         addressType: raw["addresstype"] as? String ?? "")
        }
    }

    /// 查询词和结果名字的吻合度(0...1):查询词里的字有多大比例出现在某个名字里,
    /// 取所有名字里最高的那个。比对前统一成简体、小写、去掉空白标点,
    /// 这样「浅草寺」对「淺草寺」、「台场」对「台場」都算对上。
    public static func nameScore(query: String, names: [String]) -> Double {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        return names.map { name -> Double in
            let n = normalize(name)
            guard !n.isEmpty else { return 0 }
            if n.contains(q) { return 1 }
            // 结果名字是查询词的一截(「清水寺」对「清水寺 京都」)也算,但那一截得占到
            // 一半以上——「酒店」是「新宿王子酒店」的一截,不能因此算对上。
            if q.contains(n), n.count * 2 >= q.count { return 1 }
            let pool = Set(n)
            let hit = q.filter { pool.contains($0) }.count
            return Double(hit) / Double(q.count)
        }.max() ?? 0
    }

    static func normalize(_ text: String) -> String {
        let mutable = NSMutableString(string: text.lowercased()) as CFMutableString
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        // 带声调的拉丁字母(Sensō-ji)去掉附加符号。
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return (mutable as String).filter { $0.isLetter || $0.isNumber }
    }

    /// 手动搜索列表的排序:保留 Nominatim 自己的知名度顺序,只把离锚点 `nearby` 米以内的
    /// **稳定地**挪到前面;坐标几乎重合(约 100 米内)的重复项只留第一条。
    /// 不按纯距离排:东京行程里搜「清水寺」,纯距离会把京都那座挤出列表——
    /// 一趟旅行顺道去一趟别的城市是常事,最有名的那座仍该看得到。
    public static func arrangeForPicker(_ places: [Place], anchor: TravelCoordinate?,
                                        nearby: Double = 200_000) -> [Place] {
        var seen = Set<String>()
        let unique = places.filter { place in
            seen.insert(String(format: "%.3f,%.3f", place.latitude, place.longitude)).inserted
        }
        guard let anchor else { return unique }
        let isNear: (Place) -> Bool = {
            TravelMapFraming.distance(anchor, TravelCoordinate(latitude: $0.latitude, longitude: $0.longitude))
                <= nearby
        }
        return unique.filter(isNear) + unique.filter { !isNear($0) }
    }

    /// 挑一条:国家对得上、名字对得上;有锚点时取最近的。
    public static func pick(_ places: [Place], query: String, region: String?,
                            anchor: TravelCoordinate?, maxDistance: Double? = nil,
                            areasOnly: Bool = false) -> Place? {
        let candidates = places.filter { place in
            PlaceRegion.matches(region, place.countryCode)
                && nameScore(query: query, names: place.names) >= minimumNameScore
                && (!areasOnly || areaTypes.contains(place.addressType))
        }
        guard let anchor else { return candidates.first }
        let ranked = candidates
            .map { ($0, TravelMapFraming.distance(anchor, TravelCoordinate(latitude: $0.latitude,
                                                                             longitude: $0.longitude))) }
            .sorted { $0.1 < $1.1 }
        guard let nearest = ranked.first else { return nil }
        if let maxDistance, nearest.1 > maxDistance { return nil }
        return nearest.0
    }
}
