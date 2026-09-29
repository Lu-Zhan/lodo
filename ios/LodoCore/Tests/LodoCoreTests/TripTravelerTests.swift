import XCTest
@testable import LodoCore

final class TripTravelerTests: XCTestCase {
    func testRoundTripDropsBlankUnlinked() {
        let contact = UUID()
        let list = [TripTraveler(name: " 小王 ", note: " 同事 "),
                    TripTraveler(name: "  "),
                    TripTraveler(contactUUID: contact, name: "")]
        let decoded = TripTraveler.decode(TripTraveler.encode(list))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "小王")
        XCTAssertEqual(decoded[0].note, "同事")
        XCTAssertEqual(decoded[1].contactUUID, contact)
        XCTAssertEqual(TripTraveler.encode([]), "")
        XCTAssertEqual(TripTraveler.decode("garbage"), [])
    }

    func testLinkingSkipsAlreadyLinked() {
        let a = UUID(), b = UUID()
        let existing = [TripTraveler(contactUUID: a, name: "妈妈"), TripTraveler(name: "小王")]
        let result = TripTraveler.linking([(a, "妈妈"), (b, "爸爸"), (b, "爸爸")], into: existing)
        XCTAssertEqual(result.map(\.name), ["妈妈", "小王", "爸爸"])
        XCTAssertEqual(result.last?.contactUUID, b)
    }

    func testTripTravelersPersistInData() {
        let trip = TravelTrip(title: "东京")
        XCTAssertEqual(trip.travelersData, "")
        trip.travelers = [TripTraveler(name: "小王")]
        XCTAssertFalse(trip.travelersData.isEmpty)
        XCTAssertEqual(trip.travelers.map(\.name), ["小王"])
    }

    func testTravelersSyncAndBackup() {
        let trip = TravelTrip(title: "东京")
        trip.travelers = [TripTraveler(contactUUID: UUID(), name: "妈妈")]
        let fields = SharedTripMapping.snapshot(of: trip).fields
        let copy = TravelTrip()
        SharedTripMapping.apply(fields, to: copy)
        XCTAssertEqual(copy.travelers, trip.travelers)

        let data = try! JSONEncoder().encode(trip.backup)
        let restored = TravelTrip()
        try! JSONDecoder().decode(BackupTravelTrip.self, from: data).apply(to: restored)
        XCTAssertEqual(restored.travelers, trip.travelers)
    }
}
