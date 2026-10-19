import Foundation
import SwiftData

// 健康页「经期」「用药」的三张轻量表。和 `WeightRecord` 同一个路子:不进记忆库
// (一天几条、几年下来上千条,单条也不是值得收藏的资料),不依赖健康开关(手记就能用,
// Mac 上也有)。健康 App 里的数据**不落进经期表**(显示时合并,`CyclePlan.merge`);
// 服药记录从健康 App 导入时会落进 `MedicationDose`(带 `healthSampleID` 去重),
// 因为要和 lodo 里记的放在同一条时间线上逐条看、逐条对上今天的服药时间点。
//
// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
// 几个 *Raw 字符串是持久化值,别改。

/// 手记的一次经期。
@Model
public final class PeriodRecord {
    public var uuid: UUID = UUID()
    /// 开始那天(0 点)。
    public var start: Date = Date.now
    /// 结束那天(0 点,含当天);nil = 还没结束(点了「经期开始了」还没点「结束了」)。
    public var end: Date?
    public var note: String = ""
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), start: Date, end: Date? = nil, note: String = "",
                createdAt: Date = .now) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.note = note
        self.createdAt = createdAt
    }

    public var period: CyclePlan.Period {
        CyclePlan.Period(start: start, end: end, source: .manual(uuid))
    }
}

/// 一种在吃的药。开了提醒时自动建一条重复任务(`taskUUID`),按时间点纠缠提醒;
/// 完成那条任务 = 记一笔服药(`TaskItem.medicationUUID`)。
@Model
public final class Medication {
    public var uuid: UUID = UUID()
    public var name: String = ""
    /// 每次的量,自由文字("1 片"、"5 毫升")。
    public var dosage: String = ""
    public var note: String = ""
    /// 每天几点吃,"HH:MM",可以多个;空 = 按需服用(不提醒)。
    public var times: [String] = []
    /// 周几吃(0=周一 … 6=周日,同 Scheduler);空 = 每天。
    public var days: [Int] = []
    public var reminderEnabled: Bool = false
    /// 提醒任务用闹钟(`TaskItem.alarm`)。
    public var alarm: Bool = false
    /// 自动建出来的提醒任务。
    public var taskUUID: UUID?
    /// 对应健康 App 里的那种药(`HKMedicationConcept.identifier` 的字符串形式);
    /// 从健康 App 导入或认领过才有,按它把健康 App 的服药记录对上来。
    public var healthConceptID: String?
    /// 停用(不再提醒、不出现在今天的时间点里,历史记录照留)。
    public var archived: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), name: String, dosage: String = "", note: String = "",
                times: [String] = [], days: [Int] = [], reminderEnabled: Bool = false,
                alarm: Bool = false, healthConceptID: String? = nil, createdAt: Date = .now) {
        self.uuid = uuid
        self.name = name
        self.dosage = dosage
        self.note = note
        self.times = times
        self.days = days
        self.reminderEnabled = reminderEnabled
        self.alarm = alarm
        self.healthConceptID = healthConceptID
        self.createdAt = createdAt
    }

    public var entry: MedicationPlan.Med {
        MedicationPlan.Med(id: uuid, name: name, dosage: dosage, times: times, days: days,
                           archived: archived)
    }
}

/// 一笔服药记录(吃了 / 跳过)。
@Model
public final class MedicationDose {
    public var uuid: UUID = UUID()
    /// 哪种药;药删掉之后记录照留(名字有快照)。
    public var medicationUUID: UUID?
    public var name: String = ""
    public var dosage: String = ""
    public var takenAt: Date = Date.now
    /// `taken` / `skipped`。
    public var statusRaw: String = MedicationPlan.Status.taken.rawValue
    /// `manual`(手记) / `task`(完成提醒任务) / `health`(从健康 App 导入)。
    public var sourceRaw: String = MedicationPlan.Source.manual.rawValue
    /// 由哪条提醒任务完成而来(撤销完成时连这笔一起删)。
    public var taskUUID: UUID?
    /// 健康 App 里那条服药记录的 uuid,导入去重用。
    public var healthSampleID: String?
    public var note: String = ""
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), medicationUUID: UUID?, name: String, dosage: String = "",
                takenAt: Date, status: MedicationPlan.Status = .taken,
                source: MedicationPlan.Source = .manual, taskUUID: UUID? = nil,
                healthSampleID: String? = nil, note: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.medicationUUID = medicationUUID
        self.name = name
        self.dosage = dosage
        self.takenAt = takenAt
        self.statusRaw = status.rawValue
        self.sourceRaw = source.rawValue
        self.taskUUID = taskUUID
        self.healthSampleID = healthSampleID
        self.note = note
        self.createdAt = createdAt
    }

    public var status: MedicationPlan.Status { MedicationPlan.Status(rawValue: statusRaw) ?? .taken }
    public var source: MedicationPlan.Source { MedicationPlan.Source(rawValue: sourceRaw) ?? .manual }

    public var entry: MedicationPlan.Dose {
        MedicationPlan.Dose(id: uuid, medicationID: medicationUUID, takenAt: takenAt, status: status,
                            healthSampleID: healthSampleID)
    }
}
