import XCTest
@testable import LodoCore

final class TaskAlarmPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ offset: TimeInterval, pending: Bool = true, alarm: Bool = true,
                           title: String = "吃药") -> TaskAlarmPlan.Candidate {
        TaskAlarmPlan.Candidate(id: UUID(), title: title, remindAt: now.addingTimeInterval(offset),
                                pending: pending, alarm: alarm)
    }

    func testOnlyPendingFutureTasksWithAlarm() {
        let keep = candidate(600)
        let list = [keep, candidate(-60), candidate(600, pending: false), candidate(600, alarm: false)]
        XCTAssertEqual(TaskAlarmPlan.desired(list, now: now).map(\.id), [keep.id])
    }

    func testLimitKeepsNearest() {
        let list = (1...5).map { candidate(TimeInterval($0 * 60)) }.reversed()
        let desired = TaskAlarmPlan.desired(Array(list), now: now, limit: 2)
        XCTAssertEqual(desired.map(\.fireDate), [now.addingTimeInterval(60), now.addingTimeInterval(120)])
    }

    func testUnchangedAlarmIsKept() {
        let task = candidate(600)
        let desired = TaskAlarmPlan.desired([task], now: now)
        let existing = [TaskAlarmPlan.Existing(id: task.id, fireDate: task.remindAt, alerting: false)]
        let changes = TaskAlarmPlan.changes(desired: desired, existing: existing,
                                            titles: [task.id: task.title])
        XCTAssertEqual(changes, TaskAlarmPlan.Changes())
    }

    func testMovedOrRenamedAlarmIsRescheduled() {
        let task = candidate(600)
        let desired = TaskAlarmPlan.desired([task], now: now)
        let moved = [TaskAlarmPlan.Existing(id: task.id, fireDate: task.remindAt.addingTimeInterval(-300),
                                            alerting: false)]
        let changes = TaskAlarmPlan.changes(desired: desired, existing: moved,
                                            titles: [task.id: task.title])
        XCTAssertEqual(changes.cancel, [task.id])
        XCTAssertEqual(changes.schedule.map(\.id), [task.id])

        let same = [TaskAlarmPlan.Existing(id: task.id, fireDate: task.remindAt, alerting: false)]
        let renamed = TaskAlarmPlan.changes(desired: desired, existing: same, titles: [task.id: "旧标题"])
        XCTAssertEqual(renamed.cancel, [task.id])
    }

    func testRingingAlarmOfPendingTaskIsLeftAlone() {
        let id = UUID()
        let existing = [TaskAlarmPlan.Existing(id: id, fireDate: now, alerting: true)]
        let stillPending = TaskAlarmPlan.changes(desired: [], existing: existing, pendingIDs: [id])
        XCTAssertEqual(stillPending.cancel, [])
        // 任务已经完成:撤掉(停止响铃)。
        let done = TaskAlarmPlan.changes(desired: [], existing: existing, pendingIDs: [])
        XCTAssertEqual(done.cancel, [id])
    }

    func testQuietHoursMoveTheAlarm() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let night = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now.addingTimeInterval(86400))!
        let task = TaskAlarmPlan.Candidate(id: UUID(), title: "x", remindAt: night, pending: true, alarm: true)
        let desired = TaskAlarmPlan.desired([task], now: now, quietStart: "22:00", quietEnd: "07:00",
                                            quietEnabled: true)
        XCTAssertEqual(desired.count, 1)
        XCTAssertEqual(calendar.component(.hour, from: desired[0].fireDate), 7)
    }
}
