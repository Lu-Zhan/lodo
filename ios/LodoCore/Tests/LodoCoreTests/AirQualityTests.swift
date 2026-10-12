import XCTest
@testable import LodoCore

final class AirQualityTests: XCTestCase {
    /// 2026-10 实测上海的一次返回(截短了 hourly)。
    private let sample = """
    {"latitude":31.200005,"longitude":121.5,"utc_offset_seconds":28800,"timezone":"Asia/Shanghai",
     "current":{"time":1791784800,"interval":3600,"us_aqi":97,"pm2_5":28.5,"pm10":36.8,"ozone":81.0,
       "nitrogen_dioxide":43.2,"us_aqi_pm2_5":97,"us_aqi_pm10":35,"us_aqi_ozone":27,
       "us_aqi_nitrogen_dioxide":21,"us_aqi_sulphur_dioxide":13,"us_aqi_carbon_monoxide":5},
     "hourly":{"time":[1791777600,1791781200,1791784800,1791788400,1791817200],
               "us_aqi":[98,98,97,null,116]}}
    """

    func testParsesCurrentAndHourly() throws {
        let now = Date(timeIntervalSince1970: 1791785000)
        let report = try OpenMeteoAirQuality.parse(Data(sample.utf8), now: now)
        XCTAssertEqual(report.aqi, 97)
        XCTAssertEqual(report.category, .moderate)
        XCTAssertEqual(report.dominant, .pm2_5)
        XCTAssertEqual(report.pm2_5, 28.5)
        XCTAssertEqual(report.utcOffsetSeconds, 28800)
        // null 那一小时跳过。
        XCTAssertEqual(report.hourly.map(\.aqi), [98, 98, 97, 116])
        XCTAssertEqual(report.peak(after: now)?.aqi, 116)
        // 1791817200 = 当地 23:00,还是今天;明天的点不进今天的图。
        XCTAssertEqual(report.todayHourly(now: now).count, 4)
        var tomorrow = report
        tomorrow.hourly.append(.init(date: Date(timeIntervalSince1970: 1791824400), aqi: 200))
        XCTAssertEqual(tomorrow.todayHourly(now: now).count, 4)
        XCTAssertEqual(tomorrow.peak(after: now)?.aqi, 116)
        XCTAssertTrue(report.isFresh(now: now.addingTimeInterval(60)))
        XCTAssertFalse(report.isFresh(now: now.addingTimeInterval(3600)))
    }

    func testMissingTotalFallsBackToSubIndex() throws {
        let json = #"{"current":{"us_aqi_ozone":160,"us_aqi_pm2_5":40}}"#
        let report = try OpenMeteoAirQuality.parse(Data(json.utf8))
        XCTAssertEqual(report.aqi, 160)
        XCTAssertEqual(report.dominant, .ozone)
        XCTAssertEqual(report.category, .unhealthy)
    }

    func testErrorsAreReported() {
        XCTAssertThrowsError(try OpenMeteoAirQuality.parse(Data(#"{"error":true,"reason":"bad"}"#.utf8))) {
            XCTAssertEqual($0 as? OpenMeteoAirQuality.ParseError, .api("bad"))
        }
        XCTAssertThrowsError(try OpenMeteoAirQuality.parse(Data(#"{"current":{}}"#.utf8))) {
            XCTAssertEqual($0 as? OpenMeteoAirQuality.ParseError, .noData)
        }
        XCTAssertThrowsError(try OpenMeteoAirQuality.parse(Data("oops".utf8)))
    }

    /// EPA 分级的边界。
    func testCategoryBoundaries() {
        XCTAssertEqual(AQICategory(aqi: 0), .good)
        XCTAssertEqual(AQICategory(aqi: 50), .good)
        XCTAssertEqual(AQICategory(aqi: 51), .moderate)
        XCTAssertEqual(AQICategory(aqi: 100), .moderate)
        XCTAssertEqual(AQICategory(aqi: 101), .sensitive)
        XCTAssertEqual(AQICategory(aqi: 150), .sensitive)
        XCTAssertEqual(AQICategory(aqi: 151), .unhealthy)
        XCTAssertEqual(AQICategory(aqi: 201), .veryUnhealthy)
        XCTAssertEqual(AQICategory(aqi: 301), .hazardous)
    }

    /// 只发两位小数的坐标。
    func testURLRoundsCoordinates() throws {
        let url = try XCTUnwrap(OpenMeteoAirQuality.url(latitude: 31.234567, longitude: 121.476543))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value, "31.23")
        XCTAssertEqual(items.first { $0.name == "longitude" }?.value, "121.48")
        XCTAssertTrue(items.first { $0.name == "current" }?.value?.contains("us_aqi_pm2_5") == true)
    }
}
