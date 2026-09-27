import Foundation
import MapKit
import LodoCore

/// 旅行地图上"点和点之间的真实路线"(`MKDirections`)。
///
/// 一段(相邻两个地点)一次请求,结果按两端坐标缓存在内存里(不落盘:路线会变、
/// 也没必要进备份)。一两公里内按步行、再远按驾车(`TravelMapFraming.prefersWalking`);
/// 公共交通 MapKit 只给时间不给折线,画不出来。每段都要备选路线,按
/// `RoadRoute.choose` 在"耗时不比最快的多 20%"里取最短的。
///
/// 先问苹果;苹果规划不出来(国内网络上查国外路线就是这样,同 `PlaceGeocoder` 那条
/// 只给中国数据的限制)再问 OpenStreetMap 社区的 OSRM(routing.openstreetmap.de,
/// 步行/驾车分开部署,不要 key)。遵守它的使用约定:可识别的 User-Agent、串行、
/// 每秒最多 1 次;发出去的只有两端坐标。**两边都规划失败(跨海、被限流)的那一段
/// 返回 nil,由地图退回画虚线直线**——宁可直线,也不让那一段凭空消失。
@MainActor
enum TravelRouteLoader {
    private static var cache: [String: [CLLocationCoordinate2D]] = [:]
    /// 这一轮规划失败的段,不反复重试(同 PlaceGeocoder.missed 的定位)。
    private static var failed: Set<String> = []
    /// 上一次打 OSRM 的时间:社区服务,每秒最多 1 次。
    private static var lastOSRMRequest = Date.distantPast
    /// 一次最多规划几段:MKDirections 有限流(约每分钟 50 次),一趟旅行十几段足够。
    static let budget = 40

    static func cached(_ from: TravelCoordinate, _ to: TravelCoordinate) -> [CLLocationCoordinate2D]? {
        cache[TravelMapFraming.legKey(from, to)]
    }

    /// 规划这些段里还没缓存过的,返回是否有新结果(调用方据此刷新地图)。
    static func load(_ legs: [(from: TravelCoordinate, to: TravelCoordinate)]) async -> Bool {
        var changed = false
        var requested = 0
        for leg in legs {
            let key = TravelMapFraming.legKey(leg.from, leg.to)
            guard cache[key] == nil, !failed.contains(key), requested < budget else { continue }
            requested += 1
            if Task.isCancelled { break }
            var coordinates = await directions(from: leg.from, to: leg.to)
            if coordinates == nil { coordinates = await osrm(from: leg.from, to: leg.to) }
            if let coordinates {
                cache[key] = coordinates
                changed = true
            } else {
                failed.insert(key)
            }
        }
        return changed
    }

    private static func directions(from: TravelCoordinate, to: TravelCoordinate) async
        -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = mapItem(from)
        request.destination = mapItem(to)
        request.transportType = TravelMapFraming.prefersWalking(from, to) ? .walking : .automobile
        request.requestsAlternateRoutes = true
        guard let routes = try? await MKDirections(request: request).calculate().routes,
              !routes.isEmpty else { return nil }
        let options = routes.map { route -> RoadRoute.Option in
            let polyline = route.polyline
            var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                  count: polyline.pointCount)
            polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
            return RoadRoute.Option(
                distance: route.distance, duration: route.expectedTravelTime,
                coordinates: points.map { TravelCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
        }
        return RoadRoute.choose(options).flatMap(clCoordinates)
    }

    /// OSRM 兜底。网络失败/没路线都返回 nil。
    private static func osrm(from: TravelCoordinate, to: TravelCoordinate) async -> [CLLocationCoordinate2D]? {
        guard let url = RoadRoute.url(from: from, to: to, profile: RoadRoute.profile(from: from, to: to))
        else { return nil }
        let wait = 1.1 - Date().timeIntervalSince(lastOSRMRequest)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastOSRMRequest = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("lodo/1.0 (https://github.com/Lu-Zhan/lodo)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RoadRoute.choose(RoadRoute.parse(data)).flatMap(clCoordinates)
    }

    private static func clCoordinates(_ option: RoadRoute.Option) -> [CLLocationCoordinate2D]? {
        let points = option.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return points.count >= 2 ? points : nil
    }

    private static func mapItem(_ coordinate: TravelCoordinate) -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, macOS 26.0, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }
}
