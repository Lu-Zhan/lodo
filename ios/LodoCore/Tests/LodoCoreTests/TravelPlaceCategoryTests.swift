import XCTest
@testable import LodoCore

final class TravelPlaceCategoryTests: XCTestCase {
    private func classify(_ title: String, _ place: String? = nil) -> TravelPlaceCategory {
        TravelPlaceCategory.classify(title: title, placeName: place)
    }

    func testCommonPlaces() {
        XCTAssertEqual(classify("浅草寺"), .temple)
        XCTAssertEqual(classify("伏见稻荷大社"), .temple)
        XCTAssertEqual(classify("一兰拉面", "新宿"), .restaurant)
        XCTAssertEqual(classify("东京国立博物馆"), .museum)
        XCTAssertEqual(classify("森美术馆"), .museum)
        XCTAssertEqual(classify("银座三越百货"), .shopping)
        XCTAssertEqual(classify("筑地市场"), .shopping)
        XCTAssertEqual(classify("上野公园"), .park)
        XCTAssertEqual(classify("东京塔"), .sight)
        XCTAssertEqual(classify("大阪城"), .sight)
        XCTAssertEqual(classify("京都站"), .station)
        XCTAssertEqual(classify("成田机场"), .airport)
        XCTAssertEqual(classify("% Arabica 咖啡"), .cafe)
        XCTAssertEqual(classify("鸟贵族居酒屋"), .bar)
        XCTAssertEqual(classify("Blue Bottle Coffee"), .cafe)
        XCTAssertEqual(classify("小樽运河"), .other)
    }

    func testPlaceNameUsedWhenTitleSaysNothing() {
        XCTAssertEqual(classify("午饭", nil), .other)
        XCTAssertEqual(classify("下午", "东京国立博物馆"), .museum)
    }

    func testEntrySymbols() {
        let hotel = TravelEntry(id: UUID(), kind: .lodging, title: "新宿王子酒店")
        let flight = TravelEntry(id: UUID(), kind: .flight, title: "国航")
        let ramen = TravelEntry(id: UUID(), kind: .place, title: "一兰拉面")
        XCTAssertEqual(hotel.symbolName, "bed.double")
        XCTAssertEqual(flight.symbolName, "airplane")
        XCTAssertEqual(ramen.symbolName, "fork.knife")
        XCTAssertNil(hotel.placeCategory)
        XCTAssertEqual(ramen.placeCategory, .restaurant)
    }
}
