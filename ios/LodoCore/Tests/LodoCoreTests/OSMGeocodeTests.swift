import XCTest
@testable import LodoCore

final class OSMGeocodeTests: XCTestCase {
    private let sample = """
    [{"lat":"35.7134032","lon":"139.7955265","addresstype":"amenity","name":"淺草寺",
      "address":{"country_code":"jp"},
      "namedetails":{"name:ja":"浅草寺","name:en":"Sensō-ji","alt_name:en":"Asakusa Kannon"}},
     {"lat":"35.8432297","lon":"139.7383428","addresstype":"building","name":"喜多屋酒店倉庫",
      "address":{"country_code":"jp"}},
     {"lat":"41.8049","lon":"123.3778","addresstype":"suburb","name":"浅草",
      "address":{"country_code":"cn"}},
     {"lat":"bad","lon":"1"}]
    """.data(using: .utf8)!

    func testParse() {
        let places = OSMGeocode.parse(sample)
        XCTAssertEqual(places.count, 3)
        XCTAssertEqual(places[0].countryCode, "JP")
        XCTAssertTrue(places[0].names.contains("Asakusa Kannon"))
        XCTAssertEqual(places[0].addressType, "amenity")
    }

    func testNameScoreNormalizesScriptsAndRejectsFuzzyMatches() {
        XCTAssertEqual(OSMGeocode.nameScore(query: "浅草寺", names: ["淺草寺"]), 1)
        XCTAssertEqual(OSMGeocode.nameScore(query: "台场", names: ["台場"]), 1)
        XCTAssertEqual(OSMGeocode.nameScore(query: "Sensoji", names: ["Sensō-ji"]), 1)
        XCTAssertEqual(OSMGeocode.nameScore(query: "清水寺 京都", names: ["清水寺"]), 1)
        XCTAssertLessThan(OSMGeocode.nameScore(query: "新宿王子酒店", names: ["喜多屋酒店倉庫"]),
                          OSMGeocode.minimumNameScore)
        XCTAssertLessThan(OSMGeocode.nameScore(query: "新宿王子酒店", names: ["酒店"]),
                          OSMGeocode.minimumNameScore)
    }

    func testPickChecksCountryNameAndDistance() {
        let places = OSMGeocode.parse(sample)
        let tokyo = TravelCoordinate(latitude: 35.68, longitude: 139.76)
        XCTAssertEqual(OSMGeocode.pick(places, query: "浅草寺", region: "JP", anchor: tokyo)?.latitude,
                       35.7134032)
        // 只有中国那条名字对得上时,限定日本就是没找到。
        XCTAssertNil(OSMGeocode.pick(Array(places.suffix(1)), query: "浅草", region: "JP", anchor: nil))
        XCTAssertNil(OSMGeocode.pick(places, query: "新宿王子酒店", region: "JP", anchor: tokyo))
        // 不知道国家时靠距离兜底。
        XCTAssertNil(OSMGeocode.pick(Array(places.suffix(1)), query: "浅草", region: nil,
                                     anchor: tokyo, maxDistance: 300_000))
        XCTAssertNil(OSMGeocode.pick(places, query: "浅草寺", region: "JP", anchor: nil, areasOnly: true))
    }

    func testSearchURL() throws {
        let url = try XCTUnwrap(OSMGeocode.searchURL(
            query: "清水寺", region: "JP", anchor: TravelCoordinate(latitude: 35, longitude: 135.7)))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "countrycodes" }?.value, "jp")
        XCTAssertEqual(items.first { $0.name == "viewbox" }?.value, "134.7000,36.0000,136.7000,34.0000")
        XCTAssertEqual(OSMGeocode.countryCodesParam(for: "HK"), "cn,hk,mo,tw")
        XCTAssertNil(OSMGeocode.countryCodesParam(for: nil))
    }
}
