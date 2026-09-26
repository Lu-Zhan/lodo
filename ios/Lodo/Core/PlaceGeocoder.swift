import Foundation
import MapKit
import CoreLocation
import LodoCore

/// 按地名找坐标。用的是和 `PlaceSearchView` 同一个系统能力 `MKLocalSearch`:
/// 不需要 API key,也**不要定位权限**(只按名字搜,不问"你在哪")。
///
/// 为什么需要它:行程项的地点可以是用户手打的,也可以是 AI 规划时给的一个名字,
/// 这两条路径都没有坐标,地图上就什么都画不出来。这里把"有地名、没坐标"的项
/// 主动补上——**只有真找不到的才留空**。
///
/// **搜索结果必须先验国家再用**(2026-09):`MKLocalSearch` 按设备所在地做区域偏置,
/// 实测在国内网络上 Apple 的地理服务只给中国大陆数据——搜「秋葉原」返回大连一家
/// 同名店铺、搜「清水寺」返回杭州的「Qingshuisi」,连「东京 日本」都能搜出广西平南
/// 的「Tokyo」。照单全收的后果是整趟日本行程画到中国地图上,而**画错位置比不画更糟**。
/// 所以调用方带上这趟旅行的预期国家(`region`,见 `PlaceRegion`),国家对不上的
/// 结果一律不要;宁可地图上少几个点,也不拿一个大概的位置糊弄。
enum PlaceGeocoder {
    /// 这次运行里查过、并且没找到的地名。找不到的地方(用户随手写的"朋友家")
    /// 每次打开详情页都重查一遍纯属浪费,记下来这一轮不再问;重开 app 会再试一次
    /// (内存级、不落盘,同 `unsupportedStreamEndpoints` 的定位)。
    ///
    /// 键要带上预期国家:同一个地名在"限定日本"和"不限国家"两种前提下结果不同,
    /// 混用一个键会让换了旅行之后的查询被上一趟的失败挡掉。
    private static var missed: Set<String> = []

    /// 反查过的坐标 → 国家码(反查失败的不记,下次还能再试)。`prune` 那条路径
    /// 每打开一次旅行都会把全部行程项过一遍,同一个坐标没必要问系统两次。
    private static var regionCache: [String: String] = [:]

    /// 认定"搜岔了"的距离。同一趟旅行里的地点不会离锚点上千公里,超出这个范围的
    /// 结果宁可不要。国家已知时靠国家判(更准),这条是国家未知(只填了城市名、
    /// 旅行名里也看不出国家)时的兜底。
    private static let maxDistanceFromAnchor: CLLocationDistance = 300_000

    /// 查一个地名的坐标。
    /// - Parameters:
    ///   - name: 地名本身,如"秋葉原"。
    ///   - hint: 消歧用的城市/国家,如"东京 日本";先带着它搜一次,搜不到再单搜地名。
    ///   - anchor: 已知的这趟旅行大致在哪(别的行程项的坐标,或城市本身的坐标)。
    ///     给了就用来挑最近的一条、并挡掉离谱的结果。
    ///   - region: 这趟旅行应该在哪个国家/地区(ISO 3166-1 alpha-2)。给了就**只认**
    ///     这个国家的结果;认不出国家时传 nil,退回按 anchor 距离兜底。
    ///
    /// **刻意不给 `MKLocalSearch.Request.region` 设区域偏置**:实测(macOS 26 / iOS 27)
    /// 只要带上 region,同样的查询一律返回 `MKError.placemarkNotFound`(GEOError -8),
    /// 连本来搜得到的都搜不出来了。改成拿国家 + anchor 在结果里挑,效果一样、
    /// 还不会把搜索本身搞挂。
    static func coordinate(for name: String, hint: String? = nil,
                           anchor: CLLocationCoordinate2D? = nil,
                           region: String? = nil) async
        -> CLLocationCoordinate2D? {
        let place = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return nil }
        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries = [place]
        if let trimmedHint, !trimmedHint.isEmpty, !place.contains(trimmedHint) {
            queries.insert("\(place) \(trimmedHint)", at: 0)
        }
        for query in queries {
            guard !missed.contains(missKey(query, region: region)) else { continue }
            if let found = await search(query, anchor: anchor, region: region) { return found }
        }
        return nil
    }

    /// 一个坐标落在哪个国家/地区(ISO 码),查不到返回 nil。
    ///
    /// 用来验已经存进库里的坐标:反查得到的国家和这趟旅行对不上就说明当初搜岔了。
    /// **查不到一律当"不知道"**——在只给中国数据的环境里,反查日本坐标本身就会
    /// 报错,那恰恰是坐标没问题的情形,不能当成"对不上"把它清掉。
    ///
    /// `CLGeocoder` 在 iOS 26 起标了废弃(要换 `MKReverseGeocodingRequest`),
    /// 但新 API 只给 `MKAddress` 的整串地址文字,没有 `isoCountryCode` 这一格,
    /// 拿国家名做字符串比对比现在这样更不可靠,所以继续用它(仓库里 `MKMapItem.placemark`
    /// 同样是废弃但仍在用的 API,口径一致)。
    static func regionCode(at coordinate: CLLocationCoordinate2D) async -> String? {
        let key = cacheKey(coordinate)
        if let cached = regionCache[key] { return cached }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
              let code = placemark.isoCountryCode?.uppercased(), !code.isEmpty
        else { return nil }
        regionCache[key] = code
        return code
    }

    /// 按城市名找一个**验过的**锚点:结果所属的行政区划要和城市名对得上才认。
    ///
    /// 用在"认不出这趟旅行在哪个国家"的时候(AI 规划出来的旅行常常只有「京都三日」
    /// 这么个名字)。直接拿搜索第一条当锚点是不行的——实测搜「京都」返回的是德州
    /// 一家「京都水饺王」、搜「东京」返回牡丹江的「东京新城」,锚点一歪,后面每个
    /// 地名都会挑那个错地方附近的同名店铺,整趟就都错了。
    ///
    /// 只认行政区划(locality / subAdministrativeArea / administrativeArea),
    /// **不认店名**:「京都水饺王」的名字里也有「京都」,拿名字比对等于没比。
    /// 验不出来就返回 nil,调用方据此**整步跳过**——没有判据时宁可不画点。
    static func verifiedAnchor(city: String, hint: String? = nil,
                               region: String? = nil) async -> CLLocationCoordinate2D? {
        let name = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var queries = [name]
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty, !name.contains(hint) {
            queries.insert("\(name) \(hint)", at: 0)
        }
        for query in queries {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            guard let response = try? await MKLocalSearch(request: request).start() else { continue }
            for item in response.mapItems {
                let placemark = item.placemark
                guard PlaceRegion.matches(region, placemark.isoCountryCode) else { continue }
                let areas = [placemark.locality, placemark.subAdministrativeArea,
                             placemark.administrativeArea].compactMap { $0 }
                // 「京都」对「京都市」:哪一边包含哪一边都算,免得为各语言的
                // 「市/都/府/県/省」后缀写一张表。
                let matched = areas.contains { area in
                    area.localizedCaseInsensitiveContains(name)
                        || name.localizedCaseInsensitiveContains(area)
                }
                if matched { return placemark.coordinate }
            }
        }
        return nil
    }

    private static func cacheKey(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    private static func missKey(_ query: String, region: String?) -> String {
        "\(region ?? "-")|\(query)"
    }

    private static func search(_ query: String, anchor: CLLocationCoordinate2D?,
                               region: String?) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let candidate = pick(from: response.mapItems, anchor: anchor, region: region)
            else {
                missed.insert(missKey(query, region: region))
                return nil
            }
            return candidate
        } catch {
            // 网络不通/被限流不算"找不到":不记进 missed,下次还能再试。
            if (error as? MKError)?.code == .placemarkNotFound {
                missed.insert(missKey(query, region: region))
            }
            return nil
        }
    }

    /// 挑一条:先按国家筛(知道国家的话),再有锚点时取离它最近、且没离谱的那条;
    /// 都没有就按系统给的排序取第一条。
    ///
    /// 国家筛在前面很要紧:锚点自己也可能是搜出来的,一旦它落错国家(「东京 日本」
    /// 搜出广西的 Tokyo),后面每一项都会挑那个错国家里最近的同名店铺,整趟就都歪了。
    private static func pick(from items: [MKMapItem], anchor: CLLocationCoordinate2D?,
                            region: String?) -> CLLocationCoordinate2D? {
        var candidates = items
        if let region {
            candidates = candidates.filter {
                PlaceRegion.matches(region, $0.placemark.isoCountryCode)
            }
            // 筛完一条不剩 = 这个地名在目标国家里没搜到,当作没找到。
            guard !candidates.isEmpty else { return nil }
        }
        guard let anchor else { return candidates.first?.placemark.coordinate }
        let origin = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        let nearest = candidates
            .map { item -> (CLLocationCoordinate2D, CLLocationDistance) in
                let c = item.placemark.coordinate
                return (c, origin.distance(from: CLLocation(latitude: c.latitude,
                                                            longitude: c.longitude)))
            }
            .min { $0.1 < $1.1 }
        guard let nearest else { return nil }
        // 国家已经对上时不再拿距离卡:一趟旅行跨两个城市(东京 → 京都 400km)
        // 是常事,那种距离不说明搜岔了。
        if region != nil { return nearest.0 }
        return nearest.1 <= maxDistanceFromAnchor ? nearest.0 : nil
    }
}
