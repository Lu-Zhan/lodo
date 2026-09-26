import XCTest
@testable import LodoCore

final class PlaceRegionTests: XCTestCase {
    func testCountryNameInChinese() {
        XCTAssertEqual(PlaceRegion.isoCode(in: "日本"), "JP")
        XCTAssertEqual(PlaceRegion.isoCode(in: "泰国"), "TH")
        XCTAssertEqual(PlaceRegion.isoCode(in: "韩国"), "KR")
    }

    func testCountryNameInEnglish() {
        XCTAssertEqual(PlaceRegion.isoCode(in: "Japan"), "JP")
        XCTAssertEqual(PlaceRegion.isoCode(in: "france"), "FR")
    }

    /// CLDR 里中国大陆的标准名是「中国大陆」,用户写的是「中国」——别名表要顶上。
    func testChinaAliases() {
        XCTAssertEqual(PlaceRegion.isoCode(in: "中国"), "CN")
        XCTAssertEqual(PlaceRegion.isoCode(in: "中国大陆"), "CN")
        XCTAssertEqual(PlaceRegion.isoCode(in: "香港"), "HK")
    }

    /// 旅行名里带目的地(AI 规划出来的旅行常常只有名字,没有国家字段)。
    func testCountryInsideLongerText() {
        XCTAssertEqual(PlaceRegion.isoCode(in: "日本关西七日游"), "JP")
        XCTAssertEqual(PlaceRegion.isoCode(in: "东京 · 日本"), "JP")
    }

    /// 只有城市名时认不出国家:那就没有这个判据,不能瞎猜一个。
    func testCityOnlyIsUnknown() {
        XCTAssertNil(PlaceRegion.isoCode(in: "东京四日"))
        XCTAssertNil(PlaceRegion.isoCode(in: ""))
    }

    /// 拉丁名要看词边界,不然 Malibu 会被当成 Mali。
    func testLatinNameNeedsWordBoundary() {
        XCTAssertNil(PlaceRegion.isoCode(in: "Malibu beach trip"))
        XCTAssertEqual(PlaceRegion.isoCode(in: "trip to Mali"), "ML")
    }

    /// 多个候选按顺序试:国家字段优先于旅行名。
    func testCandidatesUseFirstMatch() {
        XCTAssertEqual(PlaceRegion.isoCode(in: [nil, "", "日本", "法国"]), "JP")
        XCTAssertNil(PlaceRegion.isoCode(in: [nil, "东京"]))
    }

    func testMatchesIsLenientWhenUnknown() {
        XCTAssertTrue(PlaceRegion.matches(nil, "CN"))
        XCTAssertTrue(PlaceRegion.matches("JP", nil))
        XCTAssertTrue(PlaceRegion.matches("jp", "JP"))
    }

    func testMatchesRejectsDifferentCountry() {
        XCTAssertFalse(PlaceRegion.matches("JP", "CN"))
        XCTAssertFalse(PlaceRegion.matches("FR", "IT"))
    }

    /// 大陆/港澳台互认(用户写「中国」时香港的地点不算搜岔)。
    func testGreaterChinaMatches() {
        XCTAssertTrue(PlaceRegion.matches("CN", "HK"))
        XCTAssertTrue(PlaceRegion.matches("TW", "CN"))
        XCTAssertFalse(PlaceRegion.matches("HK", "JP"))
    }
}
