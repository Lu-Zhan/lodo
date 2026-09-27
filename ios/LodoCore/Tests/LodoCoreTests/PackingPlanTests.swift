import XCTest
@testable import LodoCore

/// 旅行用品清单纯逻辑单测。
final class PackingPlanTests: XCTestCase {
    func testGroupedKeepsFirstSeenCategoryOrderAndUncategorizedLast() {
        let trip = UUID()
        let items = [
            PackingItem(tripUUID: trip, title: "袜子", category: "衣物", sortIndex: 0),
            PackingItem(tripUUID: trip, title: "伞", category: "", sortIndex: 1),
            PackingItem(tripUUID: trip, title: "护照", category: "证件", sortIndex: 2),
            PackingItem(tripUUID: trip, title: "外套", category: "衣物", sortIndex: 3),
        ]
        let grouped = PackingPlan.grouped(items)
        XCTAssertEqual(grouped.map(\.category), ["衣物", "证件", ""])
        XCTAssertEqual(grouped[0].items.map(\.title), ["袜子", "外套"])
    }

    func testNewSuggestionsDropExistingAndDuplicates() {
        let suggestions = [
            PackingSuggestion(title: "护照", category: "证件"),
            PackingSuggestion(title: "手机 充电器", category: "电子"),
            PackingSuggestion(title: "转换插头", category: "电子"),
            PackingSuggestion(title: "转换插头", category: "电子"),
        ]
        let fresh = PackingPlan.newSuggestions(suggestions, existing: ["护照", "充电器"])
        XCTAssertEqual(fresh.map(\.title), ["转换插头"])
    }

    func testParsePackingList() throws {
        let payload: [String: Any] = ["items": [
            ["title": " 薄羽绒服 ", "category": "衣物", "reason": "早晚凉"],
            ["title": "", "category": "衣物"],
            ["title": "创可贴"],
            "乱码",
        ]]
        let parsed = try DeepSeekClient.parsePackingList(payload)
        XCTAssertEqual(parsed, [
            PackingSuggestion(title: "薄羽绒服", category: "衣物", reason: "早晚凉"),
            PackingSuggestion(title: "创可贴", category: "其他"),
        ])
    }

    func testParsePackingListRequiresItems() {
        XCTAssertThrowsError(try DeepSeekClient.parsePackingList(["text": "好的"]))
    }
}
