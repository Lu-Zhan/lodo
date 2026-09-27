import XCTest
@testable import LodoCore

final class RoadRouteTests: XCTestCase {
    func testParseGeoJSONRoutes() {
        let json = """
        {"code":"Ok","routes":[
          {"distance":3280.1,"duration":337.2,"geometry":{"type":"LineString","coordinates":[[139.79,35.71],[139.78,35.715],[139.77,35.716]]}},
          {"distance":2900,"duration":390,"geometry":{"type":"LineString","coordinates":[[139.79,35.71],[139.77,35.716]]}}
        ]}
        """.data(using: .utf8)!
        let options = RoadRoute.parse(json)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].coordinates.first, TravelCoordinate(latitude: 35.71, longitude: 139.79))
        XCTAssertEqual(options[0].coordinates.count, 3)
        XCTAssertTrue(RoadRoute.parse(#"{"code":"NoRoute","routes":[]}"#.data(using: .utf8)!).isEmpty)
    }

    func testChooseShortestAmongReasonablyFast() {
        let fast = RoadRoute.Option(distance: 5000, duration: 300, coordinates: [])
        let shortSlightlySlower = RoadRoute.Option(distance: 3500, duration: 350, coordinates: [])
        let shortestButSlow = RoadRoute.Option(distance: 3000, duration: 600, coordinates: [])
        XCTAssertEqual(RoadRoute.choose([fast, shortSlightlySlower, shortestButSlow]), shortSlightlySlower)
        XCTAssertNil(RoadRoute.choose([]))
    }

    func testProfileAndURL() {
        let a = TravelCoordinate(latitude: 35.7148, longitude: 139.7966)
        let near = TravelCoordinate(latitude: 35.7156, longitude: 139.7900)
        let far = TravelCoordinate(latitude: 35.6812, longitude: 139.7671)
        XCTAssertEqual(RoadRoute.profile(from: a, to: near), .foot)
        XCTAssertEqual(RoadRoute.profile(from: a, to: far), .car)
        XCTAssertEqual(RoadRoute.url(from: a, to: far, profile: .car)?.absoluteString,
                       "https://routing.openstreetmap.de/routed-car/route/v1/driving/139.796600,35.714800;139.767100,35.681200?overview=full&geometries=geojson&alternatives=true")
    }
}
