import XCTest
@testable import LodoCore

final class OSMGeocodeTests: XCTestCase {
    private let sample = """
    [{"osm_type":"way","osm_id":173154847,"display_name":"淺草寺, 浅草, 臺東區, 日本",
      "lat":"35.7134032","lon":"139.7955265","addresstype":"amenity","name":"淺草寺",
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
        XCTAssertEqual(places[0].name, "淺草寺")
        XCTAssertEqual(places[0].displayName, "淺草寺, 浅草, 臺東區, 日本")
        XCTAssertEqual(places[0].id, "way173154847")
        XCTAssertNotEqual(places[1].id, places[2].id)
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

    func testArrangeForPickerKeepsFamousOnesAndDedupes() {
        func place(_ id: String, _ lat: Double, _ lon: Double) -> OSMGeocode.Place {
            OSMGeocode.Place(id: id, name: id, displayName: "", latitude: lat, longitude: lon,
                             countryCode: "JP", names: [id], addressType: "amenity")
        }
        let kyoto = place("kyoto", 34.9949, 135.7850)
        let fukuoka = place("fukuoka", 33.15, 130.52)
        let yokohama = place("yokohama", 35.4300, 139.6400)
        let yokohamaDup = place("yokohama2", 35.4301, 139.6401)
        let tokyo = TravelCoordinate(latitude: 35.68, longitude: 139.76)
        let arranged = OSMGeocode.arrangeForPicker([kyoto, fukuoka, yokohama, yokohamaDup], anchor: tokyo)
        XCTAssertEqual(arranged.map(\.id), ["yokohama", "kyoto", "fukuoka"])
        XCTAssertEqual(OSMGeocode.arrangeForPicker([kyoto, fukuoka], anchor: nil).map(\.id), ["kyoto", "fukuoka"])
    }

    func testPickPrefersImportanceAndNearbyAnchor() {
        func place(_ id: String, _ lat: Double, _ lon: Double, _ importance: Double) -> OSMGeocode.Place {
            OSMGeocode.Place(id: id, name: "清水寺", displayName: "", latitude: lat, longitude: lon,
                             countryCode: "JP", names: ["清水寺"], addressType: "amenity",
                             importance: importance)
        }
        let fukuoka = place("fukuoka", 33.15, 130.52, 0.10)
        let kyoto = place("kyoto", 34.9949, 135.7850, 0.55)
        let yokohama = place("yokohama", 35.43, 139.64, 0.08)
        let all = [fukuoka, kyoto, yokohama]
        // 没有锚点:取最有名的,不取 Nominatim 的第一条。
        XCTAssertEqual(OSMGeocode.pick(all, query: "清水寺", region: "JP", anchor: nil)?.id, "kyoto")
        // 锚点在京都:附近那座。
        let kyotoAnchor = TravelCoordinate(latitude: 35.01, longitude: 135.77)
        XCTAssertEqual(OSMGeocode.pick(all, query: "清水寺", region: "JP", anchor: kyotoAnchor)?.id, "kyoto")
        // 锚点在福冈附近:取附近的,哪怕不如京都那座有名。
        let fukuokaAnchor = TravelCoordinate(latitude: 33.59, longitude: 130.40)
        XCTAssertEqual(OSMGeocode.pick(all, query: "清水寺", region: "JP", anchor: fukuokaAnchor)?.id, "fukuoka")
        // 附近一个都没有:全部里最有名的;再给距离上限就拒绝。
        let sapporo = TravelCoordinate(latitude: 43.06, longitude: 141.35)
        XCTAssertEqual(OSMGeocode.pick(all, query: "清水寺", region: "JP", anchor: sapporo)?.id, "kyoto")
        XCTAssertNil(OSMGeocode.pick(all, query: "清水寺", region: nil, anchor: sapporo, maxDistance: 300_000))
    }

    func testParseImportance() {
        let data = #"[{"lat":"1","lon":"2","name":"x","importance":0.42}]"#.data(using: .utf8)!
        XCTAssertEqual(OSMGeocode.parse(data).first?.importance, 0.42)
    }
}
