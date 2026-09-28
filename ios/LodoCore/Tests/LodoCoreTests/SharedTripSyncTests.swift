import XCTest
@testable import LodoCore

final class SharedTripSyncTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    // MARK: 合并

    func testMergeKeepsChangesToDifferentFields() {
        let base: SharedFields = ["title": .string("清水寺"), "note": .string("")]
        let local: SharedFields = ["title": .string("清水寺"), "note": .string("早点去")]
        let server: SharedFields = ["title": .string("清水寺 · 夜间"), "note": .string("")]
        let merged = SharedTripMerge.merge(base: base, local: local, server: server)
        XCTAssertEqual(merged["title"], .string("清水寺 · 夜间"))
        XCTAssertEqual(merged["note"], .string("早点去"))
    }

    func testMergeServerWinsSameField() {
        let base: SharedFields = ["title": .string("A")]
        let merged = SharedTripMerge.merge(base: base, local: ["title": .string("本地")],
                                           server: ["title": .string("远端")])
        XCTAssertEqual(merged["title"], .string("远端"))
    }

    func testMergeLocalClearedFieldSurvives() {
        let base: SharedFields = ["price": .double(100), "title": .string("A")]
        let local: SharedFields = ["title": .string("A")]
        let server: SharedFields = ["price": .double(100), "title": .string("B")]
        let merged = SharedTripMerge.merge(base: base, local: local, server: server)
        XCTAssertNil(merged["price"])
        XCTAssertEqual(merged["title"], .string("B"))
    }

    func testMergeWithoutBaseTakesServer() {
        let merged = SharedTripMerge.merge(base: nil, local: ["title": .string("本地")],
                                           server: ["title": .string("远端")])
        XCTAssertEqual(merged, ["title": .string("远端")])
    }

    // MARK: 推送计划

    func testPushPlanSavesChangedAndNewDeletesMissing() {
        let ledger: [UUID: SharedLedgerRecord] = [
            a: SharedLedgerRecord(type: .entry, fields: ["title": .string("A")]),
            b: SharedLedgerRecord(type: .entry, fields: ["title": .string("B")]),
        ]
        let local = [
            SharedRecordSnapshot(type: .entry, uuid: a, fields: ["title": .string("A")]),
            SharedRecordSnapshot(type: .entry, uuid: c, fields: ["title": .string("C")]),
        ]
        let plan = SharedTripPlanner.pushPlan(local: local, ledger: ledger)
        XCTAssertEqual(plan.saves, [c])
        XCTAssertEqual(plan.deletes, [b])
    }

    func testPushPlanEmptyWhenInSync() {
        let ledger = [a: SharedLedgerRecord(type: .packing, fields: ["packed": .bool(true)])]
        let local = [SharedRecordSnapshot(type: .packing, uuid: a, fields: ["packed": .bool(true)])]
        XCTAssertTrue(SharedTripPlanner.pushPlan(local: local, ledger: ledger).isEmpty)
    }

    // MARK: 收到的记录

    func testIncomingInsertWhenUnknown() {
        let server: SharedFields = ["title": .string("x")]
        XCTAssertEqual(SharedTripPlanner.incoming(server: server, base: nil, local: nil),
                       .insert(server))
    }

    func testIncomingSkipsLocallyDeleted() {
        XCTAssertEqual(SharedTripPlanner.incoming(server: ["title": .string("x")],
                                                  base: ["title": .string("x")], local: nil),
                       .skipDeletedLocally)
    }

    func testIncomingMergesIntoLocal() {
        let action = SharedTripPlanner.incoming(
            server: ["title": .string("B"), "packed": .bool(false)],
            base: ["title": .string("A"), "packed": .bool(false)],
            local: ["title": .string("A"), "packed": .bool(true)])
        XCTAssertEqual(action, .update(["title": .string("B"), "packed": .bool(true)]))
    }

    func testDuplicatesKeepFirst() {
        let rows = [(a, 1), (b, 2), (a, 3)]
        let extra = SharedTripPlanner.duplicates(rows, uuid: { $0.0 })
        XCTAssertEqual(extra.map(\.1), [3])
    }

    // MARK: 映射

    func testZoneNameRoundTrip() {
        XCTAssertEqual(SharedTripMapping.tripUUID(fromZoneName: SharedTripMapping.zoneName(for: a)), a)
        XCTAssertNil(SharedTripMapping.tripUUID(fromZoneName: "com.apple.coredata.cloudkit.zone"))
    }

    func testEntryRoundTripKeepsTravelFieldsAndTag() throws {
        let item = MemoryItem(kind: .text, title: "清水寺", summary: "早上去", status: .ready,
                              travelTripUUID: a, travelKind: .place,
                              travelStart: Date(timeIntervalSince1970: 1_800_000_000),
                              travelPrice: 400, travelCurrency: "JPY",
                              travelPlaceName: "清水寺", travelLatitude: 34.99, travelLongitude: 135.78)
        let snapshot = SharedTripMapping.snapshot(of: item)
        let data = try XCTUnwrap(SharedTripMapping.encode(snapshot.fields))
        let decoded = try XCTUnwrap(SharedTripMapping.decode(data))
        XCTAssertEqual(decoded, snapshot.fields)

        let copy = MemoryItem(kind: .text)
        SharedTripMapping.apply(decoded, to: copy)
        XCTAssertEqual(copy.title, "清水寺")
        XCTAssertEqual(copy.travelKind, .place)
        XCTAssertEqual(copy.travelPrice, 400)
        XCTAssertEqual(copy.travelLatitude, 34.99)
        XCTAssertNil(copy.travelEnd)
        XCTAssertTrue(copy.isTravel)
        XCTAssertEqual(SharedTripMapping.snapshot(of: copy).fields, snapshot.fields)
    }

    func testTripAndPackingRoundTrip() {
        let trip = TravelTrip(title: "京都", notes: "玩得开心", city: "京都", country: "日本")
        let tripCopy = TravelTrip()
        SharedTripMapping.apply(SharedTripMapping.snapshot(of: trip).fields, to: tripCopy)
        XCTAssertEqual(SharedTripMapping.snapshot(of: tripCopy).fields,
                       SharedTripMapping.snapshot(of: trip).fields)

        let item = PackingItem(tripUUID: a, title: "护照", category: "证件", packed: true, sortIndex: 2)
        let copy = PackingItem(tripUUID: a, title: "")
        SharedTripMapping.apply(SharedTripMapping.snapshot(of: item).fields, to: copy)
        XCTAssertEqual(copy.title, "护照")
        XCTAssertTrue(copy.packed)
        XCTAssertEqual(copy.sortIndex, 2)
    }
}

final class TravelTripEmojiTests: XCTestCase {
    func testNormalizedKeepsLastEmoji() {
        XCTAssertEqual(TravelTrip.normalizedEmoji("🗼🏖️"), "🏖️")
        XCTAssertEqual(TravelTrip.normalizedEmoji("去🇯🇵"), "🇯🇵")
        XCTAssertEqual(TravelTrip.normalizedEmoji("✈️"), "✈️")
    }

    func testNormalizedDropsNonEmoji() {
        XCTAssertEqual(TravelTrip.normalizedEmoji("东京 12#"), "")
        XCTAssertEqual(TravelTrip.normalizedEmoji(""), "")
    }

    func testDisplayEmojiDefaults() {
        let trip = TravelTrip(title: "东京")
        XCTAssertEqual(trip.displayEmoji, TravelTrip.defaultEmoji)
        trip.emoji = "🍣"
        XCTAssertEqual(trip.displayEmoji, "🍣")
    }
}
