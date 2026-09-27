import XCTest
@testable import LodoCore

final class TravelDestinationTests: XCTestCase {
    func testStripsDurationAndTripWords() {
        XCTAssertEqual(TravelDestination.stripped("东京四日"), "东京")
        XCTAssertEqual(TravelDestination.stripped("京都三日游"), "京都")
        XCTAssertEqual(TravelDestination.stripped("北海道7天自由行"), "北海道")
        XCTAssertEqual(TravelDestination.stripped("大阪之旅"), "大阪")
        XCTAssertEqual(TravelDestination.stripped("东京 · 四日"), "东京")
        XCTAssertEqual(TravelDestination.stripped("大阪-奈良两日"), "大阪")
        XCTAssertEqual(TravelDestination.stripped("Tokyo"), "Tokyo")
        // 整个名字都是尾巴词时不删成空。
        XCTAssertEqual(TravelDestination.stripped("旅行"), "旅行")
    }

    func testCandidatesPutCityFirstAndDedupe() {
        XCTAssertEqual(TravelDestination.cityCandidates(city: "京都", title: "京都三日"), ["京都"])
        XCTAssertEqual(TravelDestination.cityCandidates(city: "", title: "东京四日"), ["东京"])
        XCTAssertEqual(TravelDestination.cityCandidates(city: "大阪", title: "关西五日游"), ["大阪", "关西"])
        XCTAssertEqual(TravelDestination.cityCandidates(city: " ", title: ""), [])
    }
}
