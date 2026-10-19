import XCTest
@testable import LodoCore

final class MedicationPlanTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    /// 2026-07-08 是周三(同 SchedulerTests 的基准)。
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private let med = MedicationPlan.Med(id: UUID(), name: "维生素 D", dosage: "1 粒",
                                         times: ["20:00", "08:00"])

    func testSlotsMatchDosesInOrder() {
        // 早上那顿中午才补上:算早上那顿,晚上那顿还没到。
        let doses = [MedicationPlan.Dose(medicationID: med.id, takenAt: at(12))]
        let slots = MedicationPlan.todaySlots([med], doses: doses, now: at(13), calendar: calendar)
        XCTAssertEqual(slots.map(\.state), [.taken(at(12)), .upcoming])
        let evening = MedicationPlan.todaySlots([med], doses: doses, now: at(21), calendar: calendar)
        XCTAssertEqual(evening.map(\.state), [.taken(at(12)), .due])
    }

    func testSkippedDoseAndYesterdayIgnored() {
        let doses = [MedicationPlan.Dose(medicationID: med.id, takenAt: at(8, day: 7)),
                     MedicationPlan.Dose(medicationID: med.id, takenAt: at(8, 5), status: .skipped)]
        let slots = MedicationPlan.todaySlots([med], doses: doses, now: at(9), calendar: calendar)
        XCTAssertEqual(slots.map(\.state), [.skipped, .upcoming])
    }

    func testWeekdaysAndArchived() {
        var weekly = med
        weekly.days = [0, 4]                         // 周一、周五
        XCTAssertFalse(MedicationPlan.isScheduled(weekly, on: at(9), calendar: calendar))
        weekly.days = [2]                            // 周三
        XCTAssertTrue(MedicationPlan.isScheduled(weekly, on: at(9), calendar: calendar))
        var archived = med
        archived.archived = true
        XCTAssertTrue(MedicationPlan.todaySlots([archived], doses: [], now: at(9), calendar: calendar).isEmpty)
        let asNeeded = MedicationPlan.Med(id: UUID(), name: "布洛芬")
        XCTAssertFalse(MedicationPlan.isScheduled(asNeeded, on: at(9), calendar: calendar))
    }

    func testRepeatRule() {
        XCTAssertEqual(MedicationPlan.repeatRule(med).type, .daily)
        XCTAssertEqual(MedicationPlan.repeatRule(med).times, ["08:00", "20:00"])
        var weekly = med
        weekly.days = [4, 0, 4]
        let rule = MedicationPlan.repeatRule(weekly)
        XCTAssertEqual(rule.type, .weekly)
        XCTAssertEqual(rule.days, [0, 4])
    }

    func testHealthImportDedup() {
        let existing = [MedicationPlan.Dose(medicationID: med.id, takenAt: at(8, 2)),
                        MedicationPlan.Dose(medicationID: nil, takenAt: at(20), healthSampleID: "A")]
        XCTAssertFalse(MedicationPlan.shouldImport(sampleID: "A", medicationID: med.id, takenAt: at(22),
                                                   existing: existing))
        XCTAssertFalse(MedicationPlan.shouldImport(sampleID: "B", medicationID: med.id, takenAt: at(8, 20),
                                                   existing: existing))
        XCTAssertTrue(MedicationPlan.shouldImport(sampleID: "C", medicationID: med.id, takenAt: at(9),
                                                  existing: existing))
    }

    func testAdherenceCountsOnlyPastSlots() {
        let doses = [MedicationPlan.Dose(medicationID: med.id, takenAt: at(8, day: 7)),
                     MedicationPlan.Dose(medicationID: med.id, takenAt: at(20, day: 7)),
                     MedicationPlan.Dose(medicationID: med.id, takenAt: at(8, 10))]
        let result = MedicationPlan.adherence([med], doses: doses, days: 2, now: at(12), calendar: calendar)
        XCTAssertEqual(result.taken, 3)
        XCTAssertEqual(result.expected, 3)          // 今天 20:00 还没到
    }
}

extension MedicationPlanTests {
    // MARK: - 大按钮记的是哪一顿

    func testNextUnrecordedSlotIsFirstOpenOne() {
        let other = MedicationPlan.Med(id: UUID(), name: "钙片", times: ["07:00"])
        // 早上那顿漏了、中午记了一笔:算早上那顿,下一顿是晚上。
        let doses = [MedicationPlan.Dose(medicationID: med.id, takenAt: at(12))]
        let slots = MedicationPlan.todaySlots([med, other], doses: doses, now: at(13), calendar: calendar)
        XCTAssertEqual(MedicationPlan.nextUnrecordedSlot(of: med.id, in: slots)?.time, at(20))
        // 别的药各算各的。
        XCTAssertEqual(MedicationPlan.nextUnrecordedSlot(of: other.id, in: slots)?.time, at(7))
        // 跳过也占一顿;都记完了就没有下一顿。
        let all = doses + [MedicationPlan.Dose(medicationID: med.id, takenAt: at(20, 5), status: .skipped)]
        let done = MedicationPlan.todaySlots([med], doses: all, now: at(21), calendar: calendar)
        XCTAssertNil(MedicationPlan.nextUnrecordedSlot(of: med.id, in: done))
    }

    func testEarlyMeansMoreThanAnHourAhead() {
        let slots = MedicationPlan.todaySlots([med], doses: [], now: at(7), calendar: calendar)
        let morning = MedicationPlan.nextUnrecordedSlot(of: med.id, in: slots)!
        XCTAssertFalse(MedicationPlan.isEarly(morning, now: at(7)))          // 正好一小时
        XCTAssertTrue(MedicationPlan.isEarly(morning, now: at(6, 59)))
        XCTAssertFalse(MedicationPlan.isEarly(morning, now: at(9)))          // 已经过点
    }
}
