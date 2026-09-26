import Foundation
import MapKit
import LodoCore

/// 旅行地图上"点和点之间的真实路线"(`MKDirections`)。
///
/// 一段(相邻两个地点)一次请求,结果按两端坐标缓存在内存里(不落盘:路线会变、
/// 也没必要进备份)。一两公里内按步行、再远按驾车(`TravelMapFraming.prefersWalking`);
/// 公共交通 MapKit 只给时间不给折线,画不出来。**规划失败(没有路网数据、被限流、
/// 跨海)的那一段返回 nil,由地图退回画直线**——宁可直线,也不让那一段凭空消失。
@MainActor
enum TravelRouteLoader {
    private static var cache: [String: [CLLocationCoordinate2D]] = [:]
    /// 这一轮规划失败的段,不反复重试(同 PlaceGeocoder.missed 的定位)。
    private static var failed: Set<String> = []
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
            if let coordinates = await directions(from: leg.from, to: leg.to) {
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
        guard let route = try? await MKDirections(request: request).calculate().routes.first else {
            return nil
        }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                    count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates.isEmpty ? nil : coordinates
    }

    private static func mapItem(_ coordinate: TravelCoordinate) -> MKMapItem {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, macOS 26.0, *) {
            return MKMapItem(location: location, address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }
}
