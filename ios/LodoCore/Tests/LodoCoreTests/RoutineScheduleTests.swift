import XCTest
@testable import LodoCore

/// 定时任务的触发时间计算与结果解析。基准时间沿用项目约定的
/// 2026-07-08 周三 09:00。
final class RoutineScheduleTests: XCTestCase {
    let calendar = Calendar.current
    // 2026-07-08 09:00,周三
    var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 0))!
    }

    func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: - next

    func testNextDailyPicksTodayThenTomorrow() {
        let times = ["08:00", "21:00"]
        XCTAssertEqual(RoutineSchedule.next(after: t0, times: times, repeatType: .daily,
                                            days: []), at(8, 21, 0))
        XCTAssertEqual(RoutineSchedule.next(after: at(8, 21, 0), times: times,
                                            repeatType: .daily, days: []), at(9, 8, 0))
    }

    func testNextWeeklySkipsUnselectedDays() {
        // 只选周五(4);周三 09:00 之后的下一次是 7/10 周五 07:30
        let next = RoutineSchedule.next(after: t0, times: ["07:30"],
                                        repeatType: .weekly, days: [4])
        XCTAssertEqual(next, at(10, 7, 30))
    }

    func testNextWeeklyWithoutDaysNeverFires() {
        XCTAssertNil(RoutineSchedule.next(after: t0, times: ["07:30"],
                                          repeatType: .weekly, days: []))
    }

    func testNextIgnoresMalformedTimes() {
        // "25:00"/"abc" 丢掉,只剩 10:00 生效
        let next = RoutineSchedule.next(after: t0, times: ["25:00", "abc", "10:00"],
                                        repeatType: .daily, days: [])
        XCTAssertEqual(next, at(8, 10, 0))
        XCTAssertNil(RoutineSchedule.next(after: t0, times: ["25:00"],
                                          repeatType: .daily, days: []))
    }

    // MARK: - latestSlot / dueSlot

    func testLatestSlotLooksBackAcrossDays() {
        XCTAssertEqual(RoutineSchedule.latestSlot(atOrBefore: t0, times: ["08:00"],
                                                  repeatType: .daily, days: []),
                       at(8, 8, 0))
        // 周三 09:00 回看只选周五的任务 → 上周五 7/3
        XCTAssertEqual(RoutineSchedule.latestSlot(atOrBefore: t0, times: ["07:30"],
                                                  repeatType: .weekly, days: [4]),
                       at(3, 7, 30))
    }

    func testDueSlotRunsOncePerSlot() {
        let slot = RoutineSchedule.dueSlot(now: t0, lastSlot: nil, times: ["08:00"],
                                           repeatType: .daily, days: [])
        XCTAssertEqual(slot, at(8, 8, 0))
        // 同一槽位跑过就不再跑
        XCTAssertNil(RoutineSchedule.dueSlot(now: t0, lastSlot: at(8, 8, 0),
                                             times: ["08:00"], repeatType: .daily, days: []))
        // 下一个槽位到点后又该跑了
        XCTAssertEqual(RoutineSchedule.dueSlot(now: at(9, 8, 1), lastSlot: at(8, 8, 0),
                                               times: ["08:00"], repeatType: .daily, days: []),
                       at(9, 8, 0))
    }

    func testDueSlotSkipsStaleSlotBeyondCatchUpWindow() {
        // 早上 8 点的槽位,晚上 20:00 才打开 app —— 超过 6 小时补跑窗口,跳过
        XCTAssertNil(RoutineSchedule.dueSlot(now: at(8, 20, 0), lastSlot: nil,
                                             times: ["08:00"], repeatType: .daily, days: []))
        // 窗口内(13:59)仍然补跑
        XCTAssertEqual(RoutineSchedule.dueSlot(now: at(8, 13, 59), lastSlot: nil,
                                               times: ["08:00"], repeatType: .daily, days: []),
                       at(8, 8, 0))
    }

    // MARK: - 结果解析

    func testParseRoutineText() throws {
        guard case .text(let text) = try DeepSeekClient.parseRoutine(
            ["text": "  今天有三件事,先把周会准备完。 "], webSearchEnabled: false) else {
            return XCTFail("应解析成文字结果")
        }
        XCTAssertEqual(text, "今天有三件事,先把周会准备完。")
    }

    func testParseRoutineMissingTextThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseRoutine(["text": "   "],
                                                             webSearchEnabled: false))
        XCTAssertThrowsError(try DeepSeekClient.parseRoutine([:], webSearchEnabled: false))
    }

    func testParseRoutineToolCall() throws {
        let payload: [String: Any] = ["thought": "要查天气", "tool": "web_search",
                                      "query": "上海今天天气"]
        guard case .toolCall(let thought, .webSearch(let query)) =
                try DeepSeekClient.parseRoutine(payload, webSearchEnabled: true) else {
            return XCTFail("应解析成 web_search 工具调用")
        }
        XCTAssertEqual(thought, "要查天气")
        XCTAssertEqual(query, "上海今天天气")
    }

    /// 没开联网时 prompt 里根本没提工具,模型幻觉出来也不认(按缺 text 报错)。
    func testParseRoutineIgnoresToolWhenWebSearchDisabled() {
        let payload: [String: Any] = ["tool": "web_search", "query": "上海今天天气"]
        XCTAssertThrowsError(try DeepSeekClient.parseRoutine(payload, webSearchEnabled: false))
    }

    func testParseRoutineToolCallMissingQueryThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseRoutine(
            ["tool": "web_search"], webSearchEnabled: true))
        XCTAssertThrowsError(try DeepSeekClient.parseRoutine(
            ["tool": "web_fetch", "url": " "], webSearchEnabled: true))
    }

    // MARK: - 模型字段

    func testRoutineCaptionAndAccessors() {
        let daily = AIRoutine(name: "今日穿搭", prompt: "看天气", times: ["07:30"])
        XCTAssertEqual(daily.caption, "每天 07:30")
        XCTAssertEqual(daily.nextRun(after: t0), at(9, 7, 30))

        let weekly = AIRoutine(name: "周报", prompt: "总结", times: ["09:00", "18:00"],
                               repeatType: .weekly, days: [4, 0])
        XCTAssertEqual(weekly.caption, "每周一、五 09:00/18:00")
        XCTAssertEqual(weekly.days, [0, 4])
        XCTAssertEqual(weekly.times, ["09:00", "18:00"])
    }

    func testRoutinePresetsAreUsable() {
        for preset in AIRoutine.presets {
            let routine = AIRoutine(preset: preset)
            XCTAssertFalse(routine.name.isEmpty)
            XCTAssertFalse(routine.prompt.isEmpty)
            XCTAssertNotNil(routine.nextRun(after: t0), "\(preset.name) 应该能算出下一次触发时间")
        }
    }
}
