import XCTest
@testable import LodoCore

final class TripDestinationTests: XCTestCase {
    func testRoundTripSkipsEmpty() {
        let list = [TripDestination(city: " 上海 ", country: "中国"), TripDestination()]
        let text = TripDestination.encode(list)
        XCTAssertEqual(TripDestination.decode(text), [TripDestination(city: "上海", country: "中国")])
        XCTAssertEqual(TripDestination.encode([TripDestination()]), "")
        XCTAssertEqual(TripDestination.decode("not json"), [])
    }

    func testTripDestinationsUsePrimaryColumns() {
        let trip = TravelTrip(title: "北海道 + 上海", city: "北海道", country: "日本")
        trip.destinations = trip.destinations + [TripDestination(city: "上海", country: "中国")]
        XCTAssertEqual(trip.city, "北海道")
        XCTAssertEqual(trip.destinations.count, 2)
        XCTAssertEqual(trip.locationText, "北海道 · 日本 + 上海 · 中国")
        XCTAssertEqual(trip.destinations.map(\.regionCode), ["JP", "CN"])
    }

    func testRemovingFirstPromotesSecond() {
        let trip = TravelTrip(city: "北海道", country: "日本")
        trip.destinations = [TripDestination(), TripDestination(city: "上海", country: "中国")]
        XCTAssertEqual(trip.city, "上海")
        XCTAssertEqual(trip.country, "中国")
        XCTAssertEqual(trip.extraDestinations, "")
        trip.destinations = []
        XCTAssertTrue(trip.lacksLocation)
        XCTAssertNil(trip.locationText)
    }

    func testPreferredOrderByMention() {
        let list = [TripDestination(city: "北海道", country: "日本"),
                    TripDestination(city: "上海", country: "中国")]
        XCTAssertEqual(TripDestination.preferredOrder(list, text: "上海外滩"), [1, 0])
        XCTAssertEqual(TripDestination.preferredOrder(list, text: "二条市场"), [0, 1])
    }

    func testBackupKeepsExtraDestinations() throws {
        let trip = TravelTrip(title: "x", city: "北海道", country: "日本")
        trip.destinations = trip.destinations + [TripDestination(city: "上海", country: "中国")]
        let data = try JSONEncoder().encode(trip.backup)
        let restored = TravelTrip()
        try JSONDecoder().decode(BackupTravelTrip.self, from: data).apply(to: restored)
        XCTAssertEqual(restored.destinations, trip.destinations)
    }
}
