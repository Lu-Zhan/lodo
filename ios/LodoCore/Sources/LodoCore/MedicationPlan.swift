import Foundation

/// 健康页「用药」的纯逻辑(单测 `MedicationPlanTests`)。
public enum MedicationPlan {
    public enum Status: String, Codable { case taken, skipped }
    public enum Source: String, Codable { case manual, task, health }

    /// 健康 App 和 lodo 记的同一次服药:同一种药、时间相差不到这么久就算同一笔。
    public static let duplicateWindow: TimeInterval = 30 * 60

    public struct Med: Equatable {
        public var id: UUID
        public var name: String
        public var dosage: String
        public var times: [String]
        public var days: [Int]
        public var archived: Bool

        public init(id: UUID, name: String, dosage: String = "", times: [String] = [],
                    days: [Int] = [], archived: Bool = false) {
            self.id = id
            self.name = name
            self.dosage = dosage
            self.times = times
            self.days = days
            self.archived = archived
        }
    }

    public struct Dose: Equatable {
        public var id: UUID
        public var medicationID: UUID?
        public var takenAt: Date
        public var status: Status
        public var healthSampleID: String?

        public init(id: UUID = UUID(), medicationID: UUID?, takenAt: Date, status: Status = .taken,
                    healthSampleID: String? = nil) {
            self.id = id
            self.medicationID = medicationID
            self.takenAt = takenAt
            self.status = status
            self.healthSampleID = healthSampleID
        }
    }

    // MARK: - 今天的时间点

    public enum SlotState: Equatable {
        case taken(Date)
        case skipped
        /// 还没到点。
        case upcoming
        /// 过了点还没记。
        case due
    }

    public struct Slot: Equatable {
        public var medicationID: UUID
        public var name: String
        public var dosage: String
        public var time: Date
        public var state: SlotState
    }

    /// 这种药今天要不要吃(0=周一 … 6=周日,同 Scheduler)。
    public static func isScheduled(_ med: Med, on day: Date, calendar: Calendar = .current) -> Bool {
        guard !med.archived, !med.times.isEmpty else { return false }
        if med.days.isEmpty { return true }
        let weekday = (calendar.component(.weekday, from: day) + 5) % 7
        return med.days.contains(weekday)
    }

    /// 今天每种药的每个时间点,按时间排。当天的服药记录按时间先后依次对上时间点
    /// (第一笔算第一顿、第二笔算第二顿……),不按"离哪个点近"去猜——早上忘了吃、
    /// 中午补上,那一笔应该算早上那顿。
    public static func todaySlots(_ meds: [Med], doses: [Dose], now: Date,
                                  calendar: Calendar = .current) -> [Slot] {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var slots: [Slot] = []
        for med in meds where isScheduled(med, on: now, calendar: calendar) {
            let times = Array(Set(med.times)).sorted().compactMap { hhmm -> Date? in
                let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: dayStart)
            }
            let today = doses
                .filter { $0.medicationID == med.id && $0.takenAt >= dayStart && $0.takenAt < dayEnd }
                .sorted { $0.takenAt < $1.takenAt }
            for (index, time) in times.enumerated() {
                let state: SlotState
                if index < today.count {
                    state = today[index].status == .taken ? .taken(today[index].takenAt) : .skipped
                } else {
                    state = time > now ? .upcoming : .due
                }
                slots.append(Slot(medicationID: med.id, name: med.name, dosage: med.dosage,
                                  time: time, state: state))
            }
        }
        return slots.sorted { ($0.time, $0.name) < ($1.time, $1.name) }
    }

    /// 这种药今天还没记的第一顿(没有 = 今天都记过了 / 今天不用吃)。只有这一顿能直接
    /// 记:当天的记录按先后依次对上时间点(见 `todaySlots`),点后面那顿也会被算成它。
    public static func nextUnrecordedSlot(of medicationID: UUID, in slots: [Slot]) -> Slot? {
        slots.first { slot in
            guard slot.medicationID == medicationID else { return false }
            switch slot.state {
            case .taken, .skipped: return false
            case .upcoming, .due: return true
            }
        }
    }

    /// 离这一顿还早(超过 `earlyWindow`)时,大按钮先问一句再记,免得顺手把还没到的那顿记掉。
    public static let earlyWindow: TimeInterval = 60 * 60

    public static func isEarly(_ slot: Slot, now: Date) -> Bool {
        slot.time.timeIntervalSince(now) > earlyWindow
    }

    // MARK: - 提醒任务

    /// 提醒任务的重复规则:没选周几 = 每天,选了 = 每周那几天。
    public static func repeatRule(_ med: Med) -> (type: RepeatType, days: [Int], times: [String]) {
        let times = Array(Set(med.times)).sorted()
        return med.days.isEmpty ? (.daily, [], times) : (.weekly, Array(Set(med.days)).sorted(), times)
    }

    /// 下一次该吃的时间(建提醒任务时的 remindAt)。
    public static func nextDose(_ med: Med, after now: Date) -> Date? {
        let rule = repeatRule(med)
        guard !rule.times.isEmpty else { return nil }
        let probe = TaskData(title: med.name, remindAt: now, repeatType: rule.type,
                             repeatDays: rule.days, repeatTimes: rule.times)
        return Scheduler.nextOccurrence(probe, after: now)
    }

    // MARK: - 健康 App 导入

    /// 健康 App 的一条服药记录要不要落进来:同一条导入过的不要;同一种药 30 分钟内
    /// lodo 里已经记过一笔的也不要(多半是用户在两边各点了一次)。
    public static func shouldImport(sampleID: String, medicationID: UUID, takenAt: Date,
                                    existing: [Dose]) -> Bool {
        !existing.contains { dose in
            dose.healthSampleID == sampleID
                || (dose.medicationID == medicationID
                    && abs(dose.takenAt.timeIntervalSince(takenAt)) < duplicateWindow)
        }
    }

    /// 最近 days 天按时吃了几顿 / 应吃几顿(只算有时间点的药、今天已经过了点的那几顿)。
    public static func adherence(_ meds: [Med], doses: [Dose], days: Int, now: Date,
                                 calendar: Calendar = .current) -> (taken: Int, expected: Int) {
        var taken = 0
        var expected = 0
        let today = calendar.startOfDay(for: now)
        for offset in 0..<max(days, 0) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let probeNow = offset == 0 ? now : (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
                .addingTimeInterval(-1)
            for slot in todaySlots(meds, doses: doses, now: probeNow, calendar: calendar) {
                switch slot.state {
                case .taken: taken += 1; expected += 1
                case .skipped, .due: expected += 1
                case .upcoming: break
                }
            }
        }
        return (taken, expected)
    }
}
