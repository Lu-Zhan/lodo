import XCTest
@testable import LodoCore

/// 双向对账的纯逻辑单测(不碰 EventKit / SwiftData)。
/// 基准时间沿用 SchedulerTests 的 2026-07-08 09:00(周三)。
final class CalendarSyncPlanTests: XCTestCase {
    let calendar = Calendar.current
    var t0: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9, minute: 0))!
    }
    /// 一次查询覆盖的范围,和 CalendarBridge 里那个窗口同量级。
    var window: ClosedRange<Date> {
        t0.addingTimeInterval(-7 * 86400)...t0.addingTimeInterval(90 * 86400)
    }

    private let uuid = UUID()

    private func mirror(title: String = "开周会", start: Date? = nil, minutes: Int = 30,
                        allDay: Bool = false, recurring: Bool = false,
                        uuid: UUID? = nil) -> CalendarTaskMirror {
        let begin = start ?? t0
        return CalendarTaskMirror(uuid: uuid ?? self.uuid, title: title, start: begin,
                                  end: begin.addingTimeInterval(TimeInterval(minutes * 60)),
                                  isAllDay: allDay, isRecurring: recurring)
    }

    private func event(id: String = "E1", title: String = "开周会", start: Date? = nil,
                       minutes: Int = 30, allDay: Bool = false) -> CalendarEvent {
        let begin = start ?? t0
        return CalendarEvent(id: id, title: title, start: begin,
                             end: begin.addingTimeInterval(TimeInterval(minutes * 60)),
                             isAllDay: allDay, calendarTitle: "lodo")
    }

    private func record(_ m: CalendarTaskMirror, id: String = "E1",
                        own: Bool = true) -> CalendarSyncRecord {
        .from(m, eventID: id, isOwnCalendar: own)
    }

    // MARK: - 新建 / 无变化

    func testNewTaskCreatesEvent() {
        let plan = CalendarSyncPlanner.plan(records: [], tasks: [mirror()], events: [],
                                            window: window)
        XCTAssertEqual(plan.createEvents.count, 1)
        XCTAssertTrue(plan.updateTasks.isEmpty)
        XCTAssertTrue(plan.deleteTaskUUIDs.isEmpty)
    }

    func testNothingChangedProducesNoWork() {
        let m = mirror()
        let plan = CalendarSyncPlanner.plan(records: [record(m)], tasks: [m],
                                            events: [event()], window: window)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.records.count, 1)
    }

    // MARK: - 任务 → 事件

    func testTaskEditPushesToEvent() {
        let old = mirror()
        let edited = mirror(title: "开周会(改)", start: t0.addingTimeInterval(3600))
        let plan = CalendarSyncPlanner.plan(records: [record(old)], tasks: [edited],
                                            events: [event()], window: window)
        XCTAssertEqual(plan.updateEvents.count, 1)
        XCTAssertEqual(plan.updateEvents.first?.mirror, edited)
        XCTAssertTrue(plan.updateTasks.isEmpty)
    }

    /// 任务完成/删除后不在 tasks 里 → 自家日历的事件跟着删。
    func testTaskGoneDeletesOwnEvent() {
        let plan = CalendarSyncPlanner.plan(records: [record(mirror())], tasks: [],
                                            events: [event()], window: window)
        XCTAssertEqual(plan.deleteEventIDs, ["E1"])
        XCTAssertTrue(plan.records.isEmpty)
    }

    /// 从别人家日历认领来的那条,任务没了也**不删**用户自己的日程,只解除关系。
    func testTaskGoneDoesNotDeleteForeignEvent() {
        let plan = CalendarSyncPlanner.plan(records: [record(mirror(), own: false)],
                                            tasks: [], events: [event()], window: window)
        XCTAssertTrue(plan.deleteEventIDs.isEmpty)
        XCTAssertTrue(plan.records.isEmpty)
    }

    // MARK: - 事件 → 任务

    func testEventEditPullsIntoTask() {
        let m = mirror()
        let moved = event(title: "开周会", start: t0.addingTimeInterval(7200), minutes: 60)
        let plan = CalendarSyncPlanner.plan(records: [record(m)], tasks: [m],
                                            events: [moved], window: window)
        XCTAssertEqual(plan.updateTasks.count, 1)
        XCTAssertEqual(plan.updateTasks.first?.start, t0.addingTimeInterval(7200))
        XCTAssertEqual(plan.updateTasks.first?.durationMinutes, 60)
        XCTAssertTrue(plan.updateEvents.isEmpty)
    }

    /// 两边都改了:任务赢(提醒阶段/重复规则这些语义只有 lodo 有)。
    func testBothChangedTaskWins() {
        let old = mirror()
        let editedTask = mirror(title: "任务这边改的")
        let editedEvent = event(title: "日历那边改的")
        let plan = CalendarSyncPlanner.plan(records: [record(old)], tasks: [editedTask],
                                            events: [editedEvent], window: window)
        XCTAssertEqual(plan.updateEvents.first?.mirror.title, "任务这边改的")
        XCTAssertTrue(plan.updateTasks.isEmpty)
    }

    /// 重复事项只推不拉:在日历里挪了一次发生,推回原样、不改任务。
    func testRecurringTaskIgnoresEventEdit() {
        let m = mirror(recurring: true)
        let moved = event(start: t0.addingTimeInterval(7200))
        let plan = CalendarSyncPlanner.plan(records: [record(m)], tasks: [m],
                                            events: [moved], window: window)
        XCTAssertEqual(plan.updateEvents.count, 1)
        XCTAssertTrue(plan.updateTasks.isEmpty)
    }

    // MARK: - 删事件 = 删任务

    func testEventDeletedInsideWindowDeletesTask() {
        let plan = CalendarSyncPlanner.plan(records: [record(mirror())], tasks: [mirror()],
                                            events: [], window: window)
        XCTAssertEqual(plan.deleteTaskUUIDs, [uuid])
    }

    /// **窗口外查不到 ≠ 被删**:把任务改到半年后,不能因为这次查询没覆盖到就把它删了。
    func testEventOutsideWindowIsNotTreatedAsDeleted() {
        let far = mirror(start: t0.addingTimeInterval(200 * 86400))
        let plan = CalendarSyncPlanner.plan(records: [record(far)], tasks: [far],
                                            events: [], window: window)
        XCTAssertTrue(plan.deleteTaskUUIDs.isEmpty)
        XCTAssertEqual(plan.records.count, 1)
    }

    /// 重复事项的那条事件被删掉同样删任务(删除是明确的,不像改时间那样有歧义)。
    func testDeletingRecurringEventStillDeletesTask() {
        let m = mirror(recurring: true)
        let plan = CalendarSyncPlanner.plan(records: [record(m)], tasks: [m], events: [],
                                            window: window)
        XCTAssertEqual(plan.deleteTaskUUIDs, [uuid])
    }

    // MARK: - 账本丢了之后的重新认领

    func testClaimsEventByURLWhenLedgerIsLost() {
        let m = mirror()
        let plan = CalendarSyncPlanner.plan(records: [], tasks: [m], events: [event()],
                                            claimedUUIDs: ["E1": uuid], window: window)
        // 不该再新建一条(否则同一件任务在日历上会有两条)
        XCTAssertTrue(plan.createEvents.isEmpty)
        XCTAssertTrue(plan.updateEvents.isEmpty)
        XCTAssertEqual(plan.records.first?.eventID, "E1")
    }

    /// 认领时发现两边不一致,按任务推一次。
    func testClaimPushesWhenOutOfSync() {
        let m = mirror(title: "新标题")
        let plan = CalendarSyncPlanner.plan(records: [], tasks: [m], events: [event()],
                                            claimedUUIDs: ["E1": uuid], window: window)
        XCTAssertEqual(plan.updateEvents.count, 1)
    }

    /// 带 lodo URL 但任务早就没了的事件是孤儿,删掉。
    func testOrphanEventIsDeleted() {
        let plan = CalendarSyncPlanner.plan(records: [], tasks: [], events: [event()],
                                            claimedUUIDs: ["E1": uuid], window: window)
        XCTAssertEqual(plan.deleteEventIDs, ["E1"])
    }
}
