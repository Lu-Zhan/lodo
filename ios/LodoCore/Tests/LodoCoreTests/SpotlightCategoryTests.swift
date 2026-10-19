import XCTest
@testable import LodoCore

final class SpotlightCategoryTests: XCTestCase {
    func testIdentifierRoundTrip() {
        let uuid = UUID()
        let id = SpotlightCategory.trip.identifier(uuid)
        XCTAssertEqual(SpotlightCategory.parse(id)?.0, .trip)
        XCTAssertEqual(SpotlightCategory.parse(id)?.1, uuid)
        XCTAssertNil(SpotlightCategory.parse("trip"))
        XCTAssertNil(SpotlightCategory.parse("health:\(uuid.uuidString)"))
    }

    func testSettingsEncoding() {
        XCTAssertEqual(SpotlightCategory.decode(nil), SpotlightCategory.defaultEnabled)
        XCTAssertFalse(SpotlightCategory.defaultEnabled.contains(.asset))
        XCTAssertEqual(SpotlightCategory.decode(""), [])
        let raw = SpotlightCategory.encode([.memory, .task])
        XCTAssertEqual(raw, "task,memory")
        XCTAssertEqual(SpotlightCategory.decode(raw + ",bogus"), [.task, .memory])
    }
}
