import XCTest
@testable import LodoCore

final class PlaceCalibrationTests: XCTestCase {
    private let temple = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let hotel = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

    private func candidate(_ name: String, km: Double?) -> PlaceCalibration.Candidate {
        PlaceCalibration.Candidate(latitude: 35, longitude: 135, name: name, address: "\(name), 日本",
                                   type: "tourism", importance: 0.5, distanceKm: km)
    }

    private var items: [PlaceCalibration.Item] {
        [
            PlaceCalibration.Item(id: temple, title: "清水寺", place: "", kind: "地点",
                                  when: "第 2 天 10:00", note: "",
                                  candidates: [candidate("清水寺", km: 900), candidate("清水寺", km: 3)]),
            PlaceCalibration.Item(id: hotel, title: "新宿王子酒店", place: "新宿", kind: "住宿",
                                  when: nil, note: "",
                                  candidates: [candidate("新宿王子大饭店", km: 2)]),
        ]
    }

    func testPromptListsCandidatesOneBased() {
        let text = PlaceCalibration.prompt(trip: "旅行:京都三日", items: items)
        XCTAssertTrue(text.contains("[id:\(temple.uuidString)] 地点「清水寺」 · 第 2 天 10:00"))
        XCTAssertTrue(text.contains("  1. 清水寺 — 清水寺, 日本"))
        XCTAssertTrue(text.contains("  2. 清水寺"))
        XCTAssertTrue(text.contains("距目的地 3 km"))
        XCTAssertTrue(text.contains("(地点:新宿)"))
    }

    func testParsePicksAndNone() {
        let payload: [String: Any] = ["choices": [
            ["id": temple.uuidString, "pick": 2],
            ["id": "[id:\(hotel.uuidString.lowercased())]", "pick": NSNull()],
        ]]
        let result = PlaceCalibration.parse(payload, items: items)
        XCTAssertEqual(result[temple], .pick(1))
        XCTAssertEqual(result[hotel], PlaceCalibration.Choice.none)
    }

    func testParseIgnoresOutOfRangeAndUnknownIDs() {
        let payload: [String: Any] = ["choices": [
            ["id": temple.uuidString, "pick": 5],
            ["id": UUID().uuidString, "pick": 1],
            ["id": hotel.uuidString, "pick": "1"],
        ]]
        let result = PlaceCalibration.parse(payload, items: items)
        XCTAssertNil(result[temple])
        XCTAssertEqual(result[hotel], .pick(0))
        XCTAssertEqual(result.count, 1)
    }

    func testQueriesSearchTitleAndPlace() {
        XCTAssertEqual(PlaceCalibration.queries(title: "浅草寺", place: "浅草", isLodging: false),
                       ["浅草寺", "浅草"])
        XCTAssertEqual(PlaceCalibration.queries(title: "秋叶原(还没定时间)", place: "", isLodging: false),
                       ["秋叶原"])
        XCTAssertEqual(PlaceCalibration.queries(title: "住新宿一带", place: "新宿", isLodging: true),
                       ["新宿"])
        XCTAssertEqual(PlaceCalibration.queries(title: "清水寺", place: "清水寺", isLodging: false),
                       ["清水寺"])
    }

    private func place(_ id: String, _ lat: Double) -> OSMGeocode.Place {
        OSMGeocode.Place(id: id, name: id, displayName: id, latitude: lat, longitude: 139,
                         countryCode: "JP", names: [id], addressType: "tourism")
    }

    func testMergeKeepsBothListsAndDedupes() {
        let title = (0..<8).map { place("t\($0)", 35 + Double($0) * 0.01) }
        let area = [place("t0", 35), place("area", 36)]
        let merged = PlaceCalibration.merge([title, area])
        XCTAssertEqual(merged.count, PlaceCalibration.maxCandidates)
        XCTAssertTrue(merged.contains { $0.id == "area" })
        XCTAssertEqual(merged.filter { $0.id == "t0" }.count, 1)
    }

    func testParseMissingChoicesIsEmpty() {
        XCTAssertTrue(PlaceCalibration.parse(["foo": 1], items: items).isEmpty)
    }
}
