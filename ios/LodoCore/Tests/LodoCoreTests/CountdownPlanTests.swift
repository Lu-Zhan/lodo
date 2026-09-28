import XCTest
@testable import LodoCore

/// 倒数日纯逻辑单测。基准时间沿用 SchedulerTests 的 2026-07-08 09:00(周三)。
final class CountdownPlanTests: XCTestCase {
    let calendar = Calendar.current

    private func date(month: Int = 7, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private var now: Date { date(day: 8, hour: 9) }

    func testAllDayUpcomingCountsCalendarDays() {
        let exam = CountdownEntry(title: "考试", start: date(day: 20, hour: 15))
        XCTAssertEqual(CountdownPlan.spans(exam, now: now),
                       [CountdownSpan(milestone: .untilStart, days: 12)])
    }

    func testAllDayTodayIsStartedButNotPast() {
        let birthday = CountdownEntry(title: "生日", start: date(day: 8))
        XCTAssertEqual(CountdownPlan.primary(birthday, now: now),
                       CountdownSpan(milestone: .sinceStart, days: 0))
        XCTAssertFalse(CountdownPlan.isPast(birthday, now: now))
    }

    func testSingleDayInThePastCountsDaysSince() {
        let moved = CountdownEntry(title: "搬家", start: date(day: 1))
        XCTAssertEqual(CountdownPlan.primary(moved, now: now),
                       CountdownSpan(milestone: .sinceStart, days: 7))
        XCTAssertTrue(CountdownPlan.isPast(moved, now: now))
    }

    /// 全天的区间:结束那天整天都还算进行中。
    func testAllDayRangeOngoingThroughEndDay() {
        let holiday = CountdownEntry(title: "假期", start: date(day: 5), end: date(day: 8))
        XCTAssertEqual(CountdownPlan.spans(holiday, now: now), [
            CountdownSpan(milestone: .untilEnd, days: 0),
            CountdownSpan(milestone: .sinceStart, days: 3),
        ])
        let nextDay = date(day: 9, hour: 0, minute: 1)
        XCTAssertEqual(CountdownPlan.primary(holiday, now: nextDay),
                       CountdownSpan(milestone: .sinceEnd, days: 1))
    }

    /// 有时刻、就在今天的给到分钟。
    func testTimedEventTodayReportsMinutes() {
        let concert = CountdownEntry(title: "演唱会", start: date(day: 8, hour: 19, minute: 30),
                                     allDay: false)
        XCTAssertEqual(CountdownPlan.primary(concert, now: now),
                       CountdownSpan(milestone: .untilStart, days: 0, minutes: 630))
    }

    func testTimedEventOtherDayHasNoMinutes() {
        let flight = CountdownEntry(title: "出发", start: date(day: 10, hour: 7), allDay: false)
        XCTAssertEqual(CountdownPlan.primary(flight, now: now),
                       CountdownSpan(milestone: .untilStart, days: 2))
    }

    func testSortedUpcomingFirstThenMostRecentPast() {
        let past1 = CountdownEntry(title: "早过去", start: date(month: 6, day: 1))
        let past2 = CountdownEntry(title: "刚过去", start: date(day: 1))
        let soon = CountdownEntry(title: "快了", start: date(day: 10))
        let later = CountdownEntry(title: "还早", start: date(month: 8, day: 1))
        let ongoing = CountdownEntry(title: "进行中", start: date(day: 1), end: date(day: 9))
        let sorted = CountdownPlan.sorted([past1, later, past2, soon, ongoing], now: now)
        XCTAssertEqual(sorted.map(\.title), ["进行中", "快了", "还早", "刚过去", "早过去"])
    }

    func testWidgetEntriesOnlySelectedAndAtMostThree() {
        let entries = (1...5).map {
            CountdownEntry(title: "事\($0)", start: date(day: 10 + $0), showInWidget: $0 != 2)
        }
        XCTAssertEqual(CountdownPlan.widgetEntries(entries, now: now).map(\.title),
                       ["事1", "事3", "事4"])
    }

    /// 全天的事按全天提醒时刻往前推;过去了的不发;同一个偏移重复只发一次。
    func testRemindersForAllDayUseAllDayTime() {
        let trip = CountdownEntry(title: "出发", start: date(day: 10), end: date(day: 12),
                                  startReminders: [0, 1440, 1440, 10080], endReminders: [60])
        let reminders = CountdownPlan.reminders([trip], allDayTime: "09:00", now: now)
        XCTAssertEqual(reminders.map(\.fireDate), [
            date(day: 9, hour: 9), date(day: 10, hour: 9), date(day: 12, hour: 8),
        ])
        XCTAssertEqual(reminders.map(\.isEnd), [false, false, true])
    }

    func testRemindersForTimedEventUseItsMoment() {
        let concert = CountdownEntry(title: "演唱会", start: date(day: 8, hour: 19, minute: 30),
                                     allDay: false, startReminders: [30, 0])
        XCTAssertEqual(CountdownPlan.reminders([concert], allDayTime: "09:00", now: now)
                        .map(\.fireDate),
                       [date(day: 8, hour: 19), date(day: 8, hour: 19, minute: 30)])
    }

    // MARK: - 归档与节点

    func testArchivedExcludedFromWidgetAndReminders() {
        let archived = CountdownEntry(title: "旧事", start: date(day: 20), startReminders: [0],
                                      showInWidget: true, archived: true)
        let live = CountdownEntry(title: "新事", start: date(day: 21), startReminders: [0],
                                  showInWidget: true)
        XCTAssertEqual(CountdownPlan.widgetEntries([archived, live], now: now).map(\.title), ["新事"])
        XCTAssertEqual(CountdownPlan.reminders([archived, live], allDayTime: "09:00", now: now)
                        .map(\.title), ["新事"])
    }

    /// 在一起 2024-07-11:再过 3 天满两周年;已经 727 天,73 天后满 800 天(在 60 天外,不报)。
    func testMilestonesForPastDate() {
        let start = calendar.date(from: DateComponents(year: 2024, month: 7, day: 11))!
        let entry = CountdownEntry(title: "在一起", start: start)
        let milestones = CountdownPlan.milestones(entry, now: now)
        XCTAssertEqual(milestones.first?.kind, .anniversary(years: 2))
        XCTAssertEqual(milestones.first?.daysAway, 3)
        XCTAssertFalse(milestones.contains { if case .dayCount = $0.kind { return true } else { return false } })
        XCTAssertEqual(CountdownPlan.milestones(entry, now: now, horizonDays: 100).last?.kind,
                       .dayCount(800))
    }

    /// 正好是周年/整百天那天算今天;还没开始的只有"开始"。
    func testMilestonesTodayAndUpcoming() {
        let hundred = CountdownEntry(title: "宝宝", start: calendar.date(byAdding: .day, value: -100,
                                                                          to: date(day: 8))!)
        XCTAssertEqual(CountdownPlan.milestones(hundred, now: now).first,
                       CountdownPlan.Milestone(kind: .dayCount(100), date: date(day: 8), daysAway: 0))
        let exam = CountdownEntry(title: "考试", start: date(day: 20))
        XCTAssertEqual(CountdownPlan.milestones(exam, now: now).map(\.kind), [.start])
    }

    func testPromptSummaryListsCountUpAndMilestones() {
        let start = calendar.date(from: DateComponents(year: 2024, month: 7, day: 11))!
        let summary = CountdownPlan.promptSummary([
            CountdownEntry(title: "在一起", start: start),
            CountdownEntry(title: "归档的", start: date(day: 20), archived: true),
        ], now: now)
        XCTAssertEqual(summary, "「在一起」2024-07-11,已经 727 天;3 天后满 2 周年")
    }

    func testParseCountdownInsight() throws {
        XCTAssertEqual(try DeepSeekClient.parseCountdownInsight(["text": " 马上两周年啦 "]), "马上两周年啦")
        XCTAssertThrowsError(try DeepSeekClient.parseCountdownInsight([:]))
    }

    func testCountUpsOnlyPastAndMilestoneFirst() {
        let calendar = Calendar(identifier: .gregorian)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d))!
        }
        let now = day(2026, 7, 8)
        let together = CountdownEntry(title: "在一起", start: day(2024, 7, 11))   // 3 天后满两周年
        let job = CountdownEntry(title: "入职", start: day(2025, 1, 1))           // 下个整百天较远
        let trip = CountdownEntry(title: "旅行", start: day(2026, 6, 1), end: day(2026, 6, 5))
        let future = CountdownEntry(title: "考试", start: day(2026, 8, 1))
        let archived = CountdownEntry(title: "旧", start: day(2020, 1, 1), archived: true)
        let result = CountdownPlan.countUps([job, trip, future, archived, together],
                                            now: now, calendar: calendar)
        XCTAssertEqual(result.map(\.entry.title), ["在一起", "入职", "旅行"])
        XCTAssertEqual(result[0].next?.kind, .anniversary(years: 2))
        XCTAssertEqual(result[0].next?.daysAway, 3)
        XCTAssertNil(result[2].next)
    }
}
