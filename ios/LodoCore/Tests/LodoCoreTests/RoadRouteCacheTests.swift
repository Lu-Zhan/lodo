import XCTest
@testable import LodoCore

final class RoadRouteCacheTests: XCTestCase {
    private let a = TravelCoordinate(latitude: 35.7148, longitude: 139.7966)
    private let b = TravelCoordinate(latitude: 35.7156, longitude: 139.7714)

    func testRoundTripsThroughJSON() throws {
        var cache = RoadRouteCache()
        let key = TravelMapFraming.legKey(a, b)
        cache.insert([a, TravelCoordinate(latitude: 35.71, longitude: 139.78), b], for: key)
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(RoadRouteCache.self, from: data)
        XCTAssertEqual(decoded, cache)
        XCTAssertEqual(decoded.route(for: key)?.count, 3)
        XCTAssertEqual(decoded.route(for: key)?.last, b)
        // 地点动了,键就对不上,不会拿到旧路线。
        let moved = TravelCoordinate(latitude: 35.72, longitude: 139.7714)
        XCTAssertNil(decoded.route(for: TravelMapFraming.legKey(a, moved)))
    }

    func testEvictsOldestBeyondLimitAndRefreshesOnReinsert() {
        var cache = RoadRouteCache()
        cache.insert([a, b], for: "1", limit: 2)
        cache.insert([a, b], for: "2", limit: 2)
        cache.insert([b, a], for: "1", limit: 2)  // 重新记一次,"1" 变成最新
        cache.insert([a, b], for: "3", limit: 2)  // 挤掉最早的 "2"
        XCTAssertNotNil(cache.route(for: "1"))
        XCTAssertNil(cache.route(for: "2"))
        XCTAssertNotNil(cache.route(for: "3"))
        XCTAssertEqual(cache.route(for: "1")?.first, b)
        XCTAssertEqual(cache.count, 2)
    }

    func testIgnoresDegenerateRoutes() {
        var cache = RoadRouteCache()
        cache.insert([a], for: "x")
        XCTAssertNil(cache.route(for: "x"))
        XCTAssertEqual(cache.count, 0)
    }
}
