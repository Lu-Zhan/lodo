import XCTest
@testable import LodoCore

final class SharedAssetSyncTests: XCTestCase {
    func testZoneKindByPrefix() {
        let id = UUID()
        XCTAssertEqual(SharedZoneKind(zoneName: SharedAssetMapping.zoneName(for: id)), .assets)
        XCTAssertEqual(SharedZoneKind(zoneName: SharedTripMapping.zoneName(for: id)), .trip)
        XCTAssertNil(SharedZoneKind(zoneName: "com.apple.coredata.cloudkit.zone"))
        XCTAssertEqual(SharedZoneKind.containerUUID(fromZoneName: SharedAssetMapping.zoneName(for: id)), id)
        XCTAssertEqual(SharedZoneKind.containerUUID(fromZoneName: SharedTripMapping.zoneName(for: id)), id)
        // 两种前缀互不认。
        XCTAssertNil(SharedTripMapping.tripUUID(fromZoneName: SharedAssetMapping.zoneName(for: id)))
    }

    func testAssetRoundTripKeepsCategoryTag() {
        let item = MemoryItem(kind: .text, title: "自住房")
        item.tags = [MemoryItem.assetTagName, "房产"]
        item.assetValue = 3_000_000
        item.assetCurrency = "CNY"
        item.assetLiability = 1_200_000
        item.assetInterestRate = 3.1
        let fields = SharedAssetMapping.snapshot(ofAsset: item).fields
        let copy = MemoryItem(kind: .text)
        SharedAssetMapping.applyAsset(fields, to: copy)
        XCTAssertEqual(copy.title, "自住房")
        XCTAssertEqual(copy.tags, [MemoryItem.assetTagName, "房产"])
        XCTAssertEqual(copy.assetValue, 3_000_000)
        XCTAssertEqual(copy.assetLiability, 1_200_000)
        XCTAssertEqual(SharedAssetMapping.snapshot(ofAsset: copy).fields, fields)
    }

    func testAssetApplyAddsReservedTag() {
        let copy = MemoryItem(kind: .text)
        SharedAssetMapping.applyAsset(["title": .string("车"), "tags": .strings(["车辆"])], to: copy)
        XCTAssertTrue(copy.isAsset)
    }

    func testFinanceRoundTripSkipsReminderMarkers() {
        let card = FinanceEntry(kind: .creditCard, title: "招行", amount: 50_000,
                                dayOfMonth: 8, statementDay: 20, institution: "招商银行")
        card.reminderCycle = "2026-10-08"
        card.reminderTaskUUID = UUID()
        let fields = SharedAssetMapping.snapshot(of: card).fields
        XCTAssertNil(fields["reminderCycle"])
        XCTAssertNil(fields["reminderTaskUUID"])
        let copy = FinanceEntry(kind: .income, title: "")
        SharedAssetMapping.apply(fields, to: copy)
        XCTAssertEqual(copy.kind, .creditCard)
        XCTAssertEqual(copy.dayOfMonth, 8)
        XCTAssertEqual(copy.statementDay, 20)
        XCTAssertEqual(copy.reminderCycle, "")
        XCTAssertNil(copy.reminderTaskUUID)
        XCTAssertEqual(SharedAssetMapping.snapshot(of: copy).fields, fields)
    }

    func testJoinRules() {
        let joined = Date(timeIntervalSince1970: 1_000)
        // owner:整本台账都放进去。
        XCTAssertTrue(SharedAssetPlanner.joins(createdAt: .distantPast, joinedAt: nil))
        // 成员:加入之前记的是私人的,之后新建的才进共享台账。
        XCTAssertFalse(SharedAssetPlanner.joins(createdAt: joined.addingTimeInterval(-1), joinedAt: joined))
        XCTAssertTrue(SharedAssetPlanner.joins(createdAt: joined.addingTimeInterval(1), joinedAt: joined))
    }

    func testLedgerDecodesOldFileWithoutJoinedAt() throws {
        let old = #"{"zoneName":"trip-00000000-0000-0000-0000-00000000000A","ownerName":"me","role":"owner","tripUUID":"00000000-0000-0000-0000-00000000000A","records":[]}"#
        let ledger = try JSONDecoder().decode(SharedZoneLedger.self, from: Data(old.utf8))
        XCTAssertNil(ledger.joinedAt)
        XCTAssertEqual(ledger.kind, .trip)
    }
}
