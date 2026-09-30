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

    func testSelectionChanges() {
        let a = UUID(), b = UUID(), c = UUID(), other = UUID()
        let changes = SharedAssetPlanner.selectionChanges(current: [a, b, other], selected: [b, c],
                                                          locked: [other])
        XCTAssertEqual(changes.add, [c])
        // 别人加的(locked)即使没勾也不能移出共享。
        XCTAssertEqual(changes.remove, [a])
        let none = SharedAssetPlanner.selectionChanges(current: [a], selected: [a])
        XCTAssertTrue(none.add.isEmpty && none.remove.isEmpty)
    }

    func testRemoteDeletionOnlyDeletesOthersItems() {
        XCTAssertEqual(SharedAssetPlanner.onRemoteDeletion(createdByMe: false), .deleteLocal)
        XCTAssertEqual(SharedAssetPlanner.onRemoteDeletion(createdByMe: true), .detachOnly)
        // 拿不准时按自己的算,宁可不删。
        XCTAssertEqual(SharedAssetPlanner.onRemoteDeletion(createdByMe: nil), .detachOnly)
    }

    func testLedgerDecodesOldFileWithExtraKeys() throws {
        let old = #"{"zoneName":"assets-00000000-0000-0000-0000-00000000000A","ownerName":"me","role":"owner","tripUUID":"00000000-0000-0000-0000-00000000000A","records":[],"joinedAt":0}"#
        let ledger = try JSONDecoder().decode(SharedZoneLedger.self, from: Data(old.utf8))
        XCTAssertEqual(ledger.kind, .assets)
    }
}
