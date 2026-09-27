import Foundation

/// 规划过的实际路线(纯逻辑,`RoadRouteCacheTests`),由 app 层 `TravelRouteLoader`
/// 存进 Application Support 的一个 JSON 文件。
///
/// 为什么要记下来:路线规划要一段一段请求(苹果或 OSRM,后者每秒最多 1 次),
/// 只放内存的话每次打开旅行详情都要重新等一遍。**键是两端坐标**
/// (`TravelMapFraming.legKey`,约 1 米精度)——地点没动,键就不变,直接拿存下的
/// 路线画;地点改了、重新定位过,键自然变了,那一段重新规划,不会画出旧路线。
///
/// 和 `AgentConversationSummary` 同一个定位:**可重算的派生数据**,不进 SwiftData、
/// 不走 CloudKit、不进备份,丢了就重新规划。规划失败的段**不记**(下次还会重试)。
public struct RoadRouteCache: Codable, Equatable, Sendable {
    /// 最多记多少段,满了先丢最早记下的。一趟旅行几十段,几百段够好几趟用。
    public static let limit = 500

    /// 键 → 折线,坐标压成 [纬度, 经度, 纬度, 经度, …] 的扁平数组(比逐点带键名的
    /// JSON 小一大半,一段路线动辄上百个点)。
    private var routes: [String: [Double]]
    /// 记下的先后顺序,淘汰用。
    private var order: [String]

    public init() {
        routes = [:]
        order = []
    }

    public var count: Int { routes.count }

    public func route(for key: String) -> [TravelCoordinate]? {
        guard let flat = routes[key], flat.count >= 4 else { return nil }
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            TravelCoordinate(latitude: flat[$0], longitude: flat[$0 + 1])
        }
    }

    /// 记下一段(同一个键再记一次就覆盖、并挪到最新);少于两个点的不记。
    public mutating func insert(_ coordinates: [TravelCoordinate], for key: String,
                                limit: Int = RoadRouteCache.limit) {
        guard coordinates.count >= 2 else { return }
        routes[key] = coordinates.flatMap { [Self.round($0.latitude), Self.round($0.longitude)] }
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            routes[order.removeFirst()] = nil
        }
    }

    /// 6 位小数(约 0.1 米),够画线,文件也小一些。
    private static func round(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}
