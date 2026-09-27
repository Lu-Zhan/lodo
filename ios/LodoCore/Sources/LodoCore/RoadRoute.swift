import Foundation

/// 地图上两点之间的真实路线:OpenStreetMap 社区的 OSRM 路线服务
/// (routing.openstreetmap.de,步行/驾车分开部署)的请求地址、解析,以及在几条
/// 备选路线里挑哪条(纯逻辑,`RoadRouteTests`;真正发请求在 app 层 `TravelRouteLoader`)。
///
/// 为什么需要它:苹果的 `MKDirections` 在国内网络上规划不出国外的路线(和地名搜索
/// 同一个"只给中国数据"的限制),日本行程的每一段都退回了虚线直线。
public enum RoadRoute {
    public enum Profile: String, Sendable {
        case foot, car
    }

    public struct Option: Equatable, Sendable {
        /// 米。
        public let distance: Double
        /// 秒。
        public let duration: Double
        public let coordinates: [TravelCoordinate]

        public init(distance: Double, duration: Double, coordinates: [TravelCoordinate]) {
            self.distance = distance
            self.duration = duration
            self.coordinates = coordinates
        }
    }

    /// 一两公里内按步行(景点之间人都是走过去的),再远按驾车。
    public static func profile(from: TravelCoordinate, to: TravelCoordinate) -> Profile {
        TravelMapFraming.prefersWalking(from, to) ? .foot : .car
    }

    public static func url(from: TravelCoordinate, to: TravelCoordinate, profile: Profile) -> URL? {
        let points = [from, to].map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }
            .joined(separator: ";")
        return URL(string: "https://routing.openstreetmap.de/routed-\(profile.rawValue)/route/v1/driving/"
                   + points + "?overview=full&geometries=geojson&alternatives=true")
    }

    /// OSRM 的响应(`code == "Ok"` 才算数);几何是 GeoJSON 的 [经度, 纬度] 数组。
    public static func parse(_ data: Data) -> [Option] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["code"] as? String == "Ok",
              let routes = json["routes"] as? [[String: Any]] else { return [] }
        return routes.compactMap { route in
            guard let distance = route["distance"] as? Double,
                  let duration = route["duration"] as? Double,
                  let geometry = route["geometry"] as? [String: Any],
                  let points = geometry["coordinates"] as? [[Double]] else { return nil }
            let coordinates = points.compactMap { pair -> TravelCoordinate? in
                pair.count >= 2 ? TravelCoordinate(latitude: pair[1], longitude: pair[0]) : nil
            }
            return coordinates.count >= 2
                ? Option(distance: distance, duration: duration, coordinates: coordinates) : nil
        }
    }

    /// 耗时不比最快那条多 `tolerance` 的备选里,取距离最短的。
    /// 纯按最快会挑绕远的快速路,纯按最短可能钻进慢得多的小路;这样取"又短又不慢"的那条。
    public static let tolerance = 0.2

    public static func choose(_ options: [Option]) -> Option? {
        guard let fastest = options.map(\.duration).min() else { return nil }
        return options
            .filter { $0.duration <= fastest * (1 + tolerance) }
            .min { $0.distance < $1.distance }
    }
}
