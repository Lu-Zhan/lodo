import Foundation
import MapKit
import CoreLocation

/// 按地名找坐标。用的是和 `PlaceSearchView` 同一个系统能力 `MKLocalSearch`:
/// 不需要 API key,也**不要定位权限**(只按名字搜,不问"你在哪")。
///
/// 为什么需要它:行程项的地点可以是用户手打的,也可以是 AI 规划时给的一个名字,
/// 这两条路径都没有坐标,地图上就什么都画不出来。这里把"有地名、没坐标"的项
/// 主动补上——**只有真找不到的才留空**。
enum PlaceGeocoder {
    /// 这次运行里查过、并且没找到的地名。找不到的地方(用户随手写的"朋友家")
    /// 每次打开详情页都重查一遍纯属浪费,记下来这一轮不再问;重开 app 会再试一次
    /// (内存级、不落盘,同 `unsupportedStreamEndpoints` 的定位)。
    private static var missed: Set<String> = []

    /// 认定"搜岔了"的距离。同一趟旅行里的地点不会离锚点上千公里,超出这个范围的
    /// 结果宁可不要——实测搜"秋叶原"时,地图返回的第一条是中国东北一家同名店铺,
    /// 照单全收就会把点画到辽宁去,**画错位置比不画更糟**。
    private static let maxDistanceFromAnchor: CLLocationDistance = 300_000

    /// 查一个地名的坐标。
    /// - Parameters:
    ///   - name: 地名本身,如"秋葉原"。
    ///   - hint: 消歧用的城市/国家,如"东京 日本";先带着它搜一次,搜不到再单搜地名。
    ///   - anchor: 已知的这趟旅行大致在哪(别的行程项的坐标,或城市本身的坐标)。
    ///     给了就用来挑最近的一条、并挡掉离谱的结果。
    ///
    /// **刻意不给 `MKLocalSearch.Request.region` 设区域偏置**:实测(iOS 27 模拟器)
    /// 只要带上 region,同样的查询一律返回 `MKError.placemarkNotFound`,连本来搜得到的
    /// 都搜不出来了。改成拿 anchor 在结果里挑,效果一样、还不会把搜索本身搞挂。
    static func coordinate(for name: String, hint: String? = nil,
                           anchor: CLLocationCoordinate2D? = nil) async
        -> CLLocationCoordinate2D? {
        let place = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return nil }
        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries = [place]
        if let trimmedHint, !trimmedHint.isEmpty, !place.contains(trimmedHint) {
            queries.insert("\(place) \(trimmedHint)", at: 0)
        }
        for query in queries {
            guard !missed.contains(query) else { continue }
            if let found = await search(query, anchor: anchor) { return found }
        }
        return nil
    }

    private static func search(_ query: String,
                               anchor: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let candidate = pick(from: response.mapItems, anchor: anchor) else {
                missed.insert(query)
                return nil
            }
            return candidate
        } catch {
            // 网络不通/被限流不算"找不到":不记进 missed,下次还能再试。
            if (error as? MKError)?.code == .placemarkNotFound { missed.insert(query) }
            return nil
        }
    }

    /// 有锚点时取离它最近、且没离谱的那条;没锚点就按系统给的排序取第一条。
    private static func pick(from items: [MKMapItem],
                             anchor: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        guard let anchor else { return items.first?.placemark.coordinate }
        let origin = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
        let nearest = items
            .map { item -> (CLLocationCoordinate2D, CLLocationDistance) in
                let c = item.placemark.coordinate
                return (c, origin.distance(from: CLLocation(latitude: c.latitude,
                                                            longitude: c.longitude)))
            }
            .min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= maxDistanceFromAnchor else { return nil }
        return nearest.0
    }
}
