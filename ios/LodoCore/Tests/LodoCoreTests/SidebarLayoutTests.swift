import XCTest
@testable import LodoCore

final class SidebarLayoutTests: XCTestCase {
    private let defaults = [
        "overview", "todo", "calendar", "countdown", "memory", "contact",
        "assets", "health", "travel", "menu", "news", "agent",
    ]

    private func decode(_ string: String?) -> SidebarLayout {
        SidebarLayout.decode(string, defaultOrder: defaults)
    }

    func testDefaultsAreVisibleAndInDefaultOrder() {
        let layout = decode(nil)
        XCTAssertEqual(layout.items.map(\.id), defaults)
        XCTAssertEqual(layout.visibleIDs, defaults)
    }

    func testInvalidJSONFallsBackToDefaults() {
        for string in ["", "not json", "{}", #"[{"isVisible":false}]"#] {
            XCTAssertEqual(decode(string), decode(nil))
        }
    }

    func testRoundTripPreservesOrderAndVisibility() {
        var layout = decode(nil)
        layout.move("agent", to: "overview")
        layout.setVisible(false, for: "assets")
        layout.setVisible(false, for: "todo")
        XCTAssertEqual(decode(layout.encoded()), layout)
    }

    func testUnknownIdentifiersAreSkipped() {
        let layout = decode(#"[{"id":"futurePage","isVisible":false},{"id":"todo"}]"#)
        XCTAssertEqual(layout.items.map(\.id), ["todo"] + defaults.filter { $0 != "todo" })
        XCTAssertEqual(layout.visibleIDs.count, defaults.count)
    }

    func testDuplicateIdentifiersKeepFirstVisibilityAndPosition() {
        let layout = decode("""
        [{"id":"todo","isVisible":false},{"id":"overview"},
         {"id":"todo","isVisible":true}]
        """)
        XCTAssertEqual(layout.items.count, defaults.count)
        XCTAssertEqual(layout.items.first, SidebarItem(id: "todo", isVisible: false))
        XCTAssertEqual(layout.visibleIDs, defaults.filter { $0 != "todo" })
    }

    func testNewPagesAppendInDefaultOrder() {
        var old = decode(nil)
        old.move("agent", to: "overview")
        old.setVisible(false, for: "memory")
        let newDefaults = ["firstNew"] + defaults + ["lastNew"]
        let layout = SidebarLayout.decode(old.encoded(), defaultOrder: newDefaults)
        XCTAssertEqual(layout.items, old.items + [SidebarItem(id: "firstNew"), SidebarItem(id: "lastNew")])
    }

    func testMoveByIdentifierInBothDirections() {
        var layout = decode(nil)
        layout.move("overview", to: "calendar")
        XCTAssertEqual(Array(layout.items.prefix(3).map(\.id)), ["todo", "calendar", "overview"])
        layout.move("agent", to: "todo")
        XCTAssertEqual(layout.items.first?.id, "agent")
        let unchanged = layout
        layout.move("todo", to: "todo")
        layout.move("missing", to: "todo")
        layout.move("todo", to: "missing")
        XCTAssertEqual(layout, unchanged)
    }

    func testListMoveOffsetsInBothDirectionsAndToEnd() {
        var layout = decode(nil)
        layout.setVisible(false, for: "todo")
        layout.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        XCTAssertEqual(layout.items.map(\.id),
                       Array(defaults[2..<4]) + Array(defaults[0..<2]) + Array(defaults[4...]))
        XCTAssertFalse(layout.items[3].isVisible)
        layout.move(fromOffsets: IndexSet(integer: 11), toOffset: 0)
        XCTAssertEqual(layout.items.first?.id, "agent")
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: layout.items.count)
        XCTAssertEqual(layout.items.last?.id, "agent")
    }

    func testInvalidMoveOffsetsAreIgnored() {
        var layout = decode(nil)
        layout.move(fromOffsets: IndexSet(integer: defaults.count), toOffset: 0)
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: defaults.count + 1)
        layout.move(fromOffsets: [], toOffset: 0)
        XCTAssertEqual(layout, decode(nil))
    }

    func testHideAndShowPreservePosition() {
        var layout = decode(nil)
        layout.move("agent", to: "overview")
        let order = layout.items.map(\.id)
        layout.setVisible(false, for: "agent")
        XCTAssertEqual(layout.visibleIDs, order.filter { $0 != "agent" })
        layout.setVisible(true, for: "agent")
        XCTAssertEqual(layout.visibleIDs, order)
        layout.setVisible(false, for: "missing")
        XCTAssertEqual(layout.items.map(\.id), order)
    }

    func testAllHiddenRoundTripsToEmptyVisibleList() {
        var layout = decode(nil)
        for id in defaults { layout.setVisible(false, for: id) }
        XCTAssertTrue(decode(layout.encoded()).visibleIDs.isEmpty)
        XCTAssertEqual(decode(layout.encoded()).items.count, defaults.count)
    }

    func testLegacyAssetPreferenceSeedsOnlyMissingItem() {
        for raw in [nil, "", "not json", #"[{"id":"todo","isVisible":false}]"#] as [String?] {
            let layout = SidebarLayout.decode(raw, defaultOrder: defaults, initiallyHidden: ["assets"])
            XCTAssertFalse(layout.visibleIDs.contains("assets"))
        }
        let explicit = SidebarLayout.decode(#"[{"id":"assets","isVisible":true}]"#,
                                            defaultOrder: defaults, initiallyHidden: ["assets"])
        XCTAssertTrue(explicit.visibleIDs.contains("assets"))
        let hidden = SidebarLayout.decode(#"[{"id":"assets","isVisible":false}]"#,
                                          defaultOrder: defaults)
        XCTAssertFalse(hidden.visibleIDs.contains("assets"))
    }
}
