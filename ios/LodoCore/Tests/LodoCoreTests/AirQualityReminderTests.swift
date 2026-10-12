import XCTest
@testable import LodoCore

final class AirQualityReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// 10 月 12、13 日两天的逐小时预报:白天 60,早上 6–8 点 160,晚上 18 点起 110。
    private var hourly: [AirQualityReport.HourPoint] {
        (12...13).flatMap { day in
            (0..<24).map { hour -> AirQualityReport.HourPoint in
                let aqi = (6..<9).contains(hour) ? 160 : hour >= 18 ? 110 : 60
                return .init(date: date(day, hour), aqi: aqi)
            }
        }
    }

    func testParseTimes() {
        XCTAssertEqual(AirQualityReminderPlan.parseTimes("18:30, 7:00,07:00,25:00,abc"), ["07:00", "18:30"])
        XCTAssertEqual(AirQualityReminderPlan.parseTimes(""), [])
        XCTAssertEqual(AirQualityReminderPlan.parseTimes("01:00,02:00,03:00,04:00,05:00").count, 4)
        XCTAssertEqual(AirQualityReminderPlan.encode(["18:00", "07:30"]), "07:30,18:00")
    }

    /// 早上 7 点的提醒看 7–10 点里最高的(160,不健康),建议含戴口罩、不要晨跑;
    /// 已经过了的时间点排到明天。
    func testSlotsUseForecastWindowAndRollToTomorrow() {
        let now = date(12, 12)
        let slots = AirQualityReminderPlan.slots(times: ["07:00", "18:00"], hourly: hourly,
                                                 now: now, calendar: calendar)
        XCTAssertEqual(slots.map(\.fireDate), [date(12, 18), date(13, 7)])
        XCTAssertEqual(slots[0].aqi, 110)
        XCTAssertEqual(slots[0].category, .sensitive)
        XCTAssertEqual(slots[0].tips, [.reduceOutdoorExercise, .sensitiveMask])
        XCTAssertEqual(slots[1].aqi, 160)
        XCTAssertEqual(slots[1].tips, [.wearMask, .skipMorningRun, .closeWindows])
    }

    /// 只在不好时提醒:中午 12 点那条(60)不排;预报没覆盖的时间点不排。
    func testOnlyWhenUnhealthyAndMissingForecast() {
        let now = date(12, 9)
        let slots = AirQualityReminderPlan.slots(times: ["12:00", "18:30"], hourly: hourly, now: now,
                                                 onlyWhenUnhealthy: true, calendar: calendar)
        XCTAssertEqual(slots.map(\.time), ["18:30"])
        let late = AirQualityReminderPlan.slots(times: ["12:00"], hourly: hourly, now: date(13, 13),
                                                calendar: calendar)
        XCTAssertTrue(late.isEmpty, "14 号没有预报,不编数字")
    }

    func testTipsByLevel() {
        XCTAssertEqual(AirQualityReminderPlan.tips(aqi: 30, hour: 7), [.goodForMorningRun, .openWindows])
        XCTAssertEqual(AirQualityReminderPlan.tips(aqi: 30, hour: 15), [.goodForOutdoor, .openWindows])
        XCTAssertEqual(AirQualityReminderPlan.tips(aqi: 260, hour: 7), [.stayIndoors, .wearMask, .runPurifier])
    }
}
