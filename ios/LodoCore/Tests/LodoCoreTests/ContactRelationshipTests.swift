import XCTest
@testable import LodoCore

final class ContactRelationshipTests: XCTestCase {
    @MainActor
    func testInvolvesBothSides() {
        let a = UUID()
        let b = UUID()
        let edge = ContactRelationship(memoryUUIDA: a, memoryUUIDB: b, label: "同事")
        XCTAssertTrue(edge.involves(a))
        XCTAssertTrue(edge.involves(b))
        XCTAssertFalse(edge.involves(UUID()))
    }

    @MainActor
    func testOtherThanReturnsOppositeEnd() {
        let a = UUID()
        let b = UUID()
        let edge = ContactRelationship(memoryUUIDA: a, memoryUUIDB: b, label: "同事")
        XCTAssertEqual(edge.other(than: a), b)
        XCTAssertEqual(edge.other(than: b), a)
        XCTAssertNil(edge.other(than: UUID()))
    }

    @MainActor
    func testSelfPairEdgeCase() {
        // 理论上不该出现(UI 不允许选自己连自己),但纯逻辑层不该假设调用方
        // 一定会挡住——两端相同时 involves 仍应为 true,other(than:) 返回自身。
        let a = UUID()
        let edge = ContactRelationship(memoryUUIDA: a, memoryUUIDB: a, label: "自己")
        XCTAssertTrue(edge.involves(a))
        XCTAssertEqual(edge.other(than: a), a)
    }
}
