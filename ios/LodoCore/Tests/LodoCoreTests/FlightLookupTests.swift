import XCTest
@testable import LodoCore

/// 航班查询的解析单测(不发请求)。
/// ⚠️ 这里的样本 payload 是按 AeroDataBox 公开文档的形状手写的,**不是真实响应**
/// ——实现时没法访问它的文档站验证。拿到真实响应后应该把样本换成真的那份,
/// 再按需要调 parseFlights;调用方不受影响。
final class FlightLookupTests: XCTestCase {

    private func sample() -> [[String: Any]] {
        [[
            "number": "CA 167",
            "status": "Scheduled",
            "airline": ["name": "Air China", "iata": "CA"],
            "departure": [
                "airport": [
                    "iata": "PEK", "icao": "ZBAA", "name": "Beijing Capital",
                    "municipalityName": "Beijing",
                    "location": ["lat": 40.0799, "lon": 116.6031],
                ],
                "scheduledTime": ["utc": "2026-07-08 01:00Z", "local": "2026-07-08 09:00+08:00"],
                "terminal": "3",
            ],
            "arrival": [
                "airport": [
                    "iata": "NRT", "name": "Tokyo Narita",
                    "location": ["lat": 35.7647, "lon": 140.3863],
                ],
                "scheduledTime": ["utc": "2026-07-08 05:00Z", "local": "2026-07-08 14:00+09:00"],
            ],
        ]]
    }

    func testParseFlight() throws {
        let flights = try FlightLookupClient.parseFlights(sample())
        XCTAssertEqual(flights.count, 1)
        let flight = flights[0]
        XCTAssertEqual(flight.number, "CA 167")
        XCTAssertEqual(flight.airlineName, "Air China")
        XCTAssertEqual(flight.departure.iata, "PEK")
        XCTAssertEqual(flight.departure.airportName, "Beijing Capital")
        XCTAssertEqual(flight.departure.terminal, "3")
        XCTAssertEqual(flight.departure.latitude!, 40.0799, accuracy: 0.0001)
        XCTAssertEqual(flight.arrival.iata, "NRT")
        XCTAssertTrue(flight.arrival.hasCoordinate)
    }

    /// 顶层是 {"flights": [...]} 时同样能解析。
    func testParseWrappedPayload() throws {
        let flights = try FlightLookupClient.parseFlights(["flights": sample()])
        XCTAssertEqual(flights.count, 1)
    }

    /// 单条也接受(某些接口返回的是对象而不是数组)。
    func testParseSingleObject() throws {
        let flights = try FlightLookupClient.parseFlights(sample()[0])
        XCTAssertEqual(flights.count, 1)
    }

    /// 缺航班号的条目跳过,不让整次查询白费。
    func testSkipsItemsWithoutNumber() throws {
        var bad = sample()[0]
        bad.removeValue(forKey: "number")
        let flights = try FlightLookupClient.parseFlights([bad] + sample())
        XCTAssertEqual(flights.map(\.number), ["CA 167"])
    }

    /// 机场/时间整块缺失时留空,不编——覆盖不到的小机场就是这样。
    func testMissingAirportLeavesFieldsNil() throws {
        let flights = try FlightLookupClient.parseFlights([[
            "number": "XX1", "departure": [:] as [String: Any],
        ]])
        let endpoint = flights[0].departure
        XCTAssertNil(endpoint.airportName)
        XCTAssertNil(endpoint.scheduledTime)
        XCTAssertNil(endpoint.displayName)
        XCTAssertFalse(endpoint.hasCoordinate)
        XCTAssertEqual(flights[0].arrival, FlightLookupClient.Endpoint())
    }

    /// 老的 movement 形状也认(FIDS 那组接口用的是它)。
    func testAcceptsLegacyMovementShape() throws {
        let flights = try FlightLookupClient.parseFlights([[
            "number": "CA 167",
            "movement": ["airport": ["iata": "PEK"],
                         "scheduledTime": ["local": "2026-07-08 09:00+08:00"]],
        ]])
        XCTAssertEqual(flights[0].departure.iata, "PEK")
        XCTAssertNotNil(flights[0].departure.scheduledTime)
    }

    /// 时间优先取 local:跨时区时按 utc 再转手机时区会差好几个小时。
    /// 09:00+08:00 == 01:00Z,取 local 解析出来的瞬间应该正是 01:00Z。
    func testPrefersLocalTime() throws {
        let flights = try FlightLookupClient.parseFlights(sample())
        let expected = FlightLookupClient.parseTimestamp("2026-07-08 01:00Z")
        XCTAssertEqual(flights[0].departure.scheduledTime, expected)
    }

    /// 有改签时刻就用改签的——用户要的是"我几点到机场"。
    func testRevisedTimeWins() throws {
        let flights = try FlightLookupClient.parseFlights([[
            "number": "CA 167",
            "departure": [
                "scheduledTime": ["local": "2026-07-08 09:00+08:00"],
                "revisedTime": ["local": "2026-07-08 11:30+08:00"],
            ],
        ]])
        XCTAssertEqual(flights[0].departure.scheduledTime,
                       FlightLookupClient.parseTimestamp("2026-07-08 11:30+08:00"))
    }

    /// 空格分隔和 T 分隔、带不带秒都能解析。
    func testTimestampFormats() {
        XCTAssertNotNil(FlightLookupClient.parseTimestamp("2026-07-08 09:00+08:00"))
        XCTAssertNotNil(FlightLookupClient.parseTimestamp("2026-07-08 09:00:30+08:00"))
        XCTAssertNotNil(FlightLookupClient.parseTimestamp("2026-07-08T09:00Z"))
        XCTAssertNil(FlightLookupClient.parseTimestamp("七月八号早上九点"))
    }

    func testDisplayName() {
        XCTAssertEqual(
            FlightLookupClient.Endpoint(airportName: "Tokyo Narita", iata: "NRT").displayName,
            "Tokyo Narita (NRT)")
        XCTAssertEqual(FlightLookupClient.Endpoint(iata: "NRT").displayName, "NRT")
        XCTAssertEqual(FlightLookupClient.Endpoint(airportName: "某机场").displayName, "某机场")
    }

    func testEmptyPayloadThrows() {
        XCTAssertThrowsError(try FlightLookupClient.parseFlights("不是 JSON 对象"))
        XCTAssertTrue(try! FlightLookupClient.parseFlights([[String: Any]]()).isEmpty)
    }
}
