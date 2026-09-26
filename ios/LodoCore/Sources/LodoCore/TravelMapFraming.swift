import Foundation

/// 旅行详情页的地图取景与路线分段(纯逻辑,`TravelMapFramingTests`)。
///
/// 详情页改成「整屏地图 + 下面半高的行程面板」之后,地图的下半截常年被面板盖着。
/// 直接把点框进整块地图,一半的点会落在面板底下;这里算的取景只把点放进**露出来
/// 的上半截**里。不 import MapKit——结果是中心点 + 跨度,由视图换成 `MKCoordinateRegion`。
public enum TravelMapFraming {
    public struct Frame: Equatable, Sendable {
        public let center: TravelCoordinate
        public let latitudeDelta: Double
        public let longitudeDelta: Double
    }

    /// 把一组点框进地图上没被遮住的那部分。
    /// - coveredFraction: 地图底部被面板遮住的比例(0 = 不遮;半高面板约 0.5)。
    /// - topCoveredFraction: 顶部被导航栏/状态栏盖住的比例(点落在那儿会被按钮挡住)。
    /// - padding: 包围盒外再留的余量倍数。
    /// - minimumSpan: 只有一个点(或几个点挤在一起)时的最小跨度,别缩到最深。
    public static func frame(_ points: [TravelCoordinate], coveredFraction: Double = 0,
                             topCoveredFraction: Double = 0,
                             padding: Double = 1.4, minimumSpan: Double = 0.02) -> Frame? {
        guard let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max()
        else { return nil }
        let bottom = min(max(coveredFraction, 0), 0.8)
        let top = min(max(topCoveredFraction, 0), 0.8 - bottom)
        let visibleShare = 1 - bottom - top
        let visibleLat = max((maxLat - minLat) * padding, minimumSpan)
        let totalLat = min(visibleLat / visibleShare, 170)
        let midLat = (minLat + maxLat) / 2
        // 露出来的是中间那截 [bottom, 1 - top];让包围盒的中点落在那截的正中:
        // 地图中心 = 中点 + total × (top - bottom) / 2。
        let centerLat = midLat + totalLat * (top - bottom) / 2
        let lonDelta = min(max((maxLon - minLon) * padding, minimumSpan), 360)
        return Frame(center: TravelCoordinate(latitude: centerLat, longitude: (minLon + maxLon) / 2),
                     latitudeDelta: totalLat, longitudeDelta: lonDelta)
    }

    /// 一天的路线拆成相邻两点一段(按顺序)。少于两个点就没有线可画。
    public static func legs(_ points: [TravelCoordinate]) -> [(from: TravelCoordinate, to: TravelCoordinate)] {
        guard points.count >= 2 else { return [] }
        return zip(points, points.dropFirst())
            .filter { $0 != $1 }
            .map { (from: $0, to: $1) }
    }

    /// 两点之间的大圆距离(米)。
    public static func distance(_ a: TravelCoordinate, _ b: TravelCoordinate) -> Double {
        let radius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    /// 这一段按步行还是开车规划路线。一两公里以内的景点之间人都是走过去的,
    /// 按驾车画会绕出一圈单行道。
    public static let walkingThreshold: Double = 1_500

    public static func prefersWalking(_ a: TravelCoordinate, _ b: TravelCoordinate) -> Bool {
        distance(a, b) <= walkingThreshold
    }

    /// 路线缓存键:两端坐标保留 5 位小数(约 1 米)。
    public static func legKey(_ a: TravelCoordinate, _ b: TravelCoordinate) -> String {
        String(format: "%.5f,%.5f>%.5f,%.5f", a.latitude, a.longitude, b.latitude, b.longitude)
    }
}
