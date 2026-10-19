import Foundation
import SwiftData
import LodoCore

/// 用药的落库与连带更新:提醒任务、服药记录、健康 App 导入。纯逻辑在 `MedicationPlan`。
///
/// - **提醒 = 一条普通的重复任务**(「服药:xx」,`TaskItem.medicationUUID` 指回这种药),
///   纠缠、稍等、闹钟、通知按钮全都复用任务那一套;完成那条任务 = 记一笔服药
///   (`NotificationManager.complete` 里调 `logDose(fromTask:)`,所有完成路径都经过那里)。
/// - 用户在任务页把那条任务删了 = 关掉这种药的提醒(`reminderActive` 判断),不再偷偷建回来。
/// - 健康 App 只读:药品列表和服药记录能导进来,lodo 里记的写不回健康 App
///   (HealthKit 不开放第三方写服药记录)。
@MainActor
enum MedicationStore {

    // MARK: - 药品

    static func save(_ med: Medication, context: ModelContext) {
        try? context.save()
        syncTask(for: med, context: context)
    }

    static func delete(_ med: Medication, context: ModelContext) {
        if let task = task(med.taskUUID, context: context) {
            TaskActions.delete(task, context: context)
        }
        context.delete(med)
        try? context.save()
    }

    /// 让提醒任务和这种药的设置对上:该有就建/改,不该有就删。
    static func syncTask(for med: Medication, context: ModelContext) {
        let existing = task(med.taskUUID, context: context)
        let wanted = med.reminderEnabled && !med.archived && !med.times.isEmpty
        guard wanted, let next = MedicationPlan.nextDose(med.entry, after: Date()) else {
            if let existing { TaskActions.delete(existing, context: context) }
            med.taskUUID = nil
            try? context.save()
            return
        }
        let rule = MedicationPlan.repeatRule(med.entry)
        var parsed = ParsedTask(title: taskTitle(for: med), remindAt: next, allDay: false,
                                repeatType: rule.type, repeatDays: rule.days, repeatTimes: rule.times)
        parsed.alarm = med.alarm
        if let existing, existing.status == .pending {
            parsed.project = existing.project
            // 规则没变就不碰:apply 会把 nextRemindAt 拉回下一次,正在稍等的那一顿会被重置。
            let unchanged = existing.title == parsed.title && existing.repeatType == rule.type
                && existing.repeatDays == rule.days && existing.repeatTimes == rule.times
                && existing.alarm == med.alarm
            if !unchanged { TaskActions.apply(parsed, to: existing, context: context) }
            existing.medicationUUID = med.uuid
        } else {
            let task = TaskActions.create(parsed, context: context)
            task.medicationUUID = med.uuid
            med.taskUUID = task.uuid
        }
        try? context.save()
    }

    /// 提醒是不是真的在跑:开了提醒、而且那条任务还在、没完成。用户在任务页把任务删了
    /// 就是"关掉了"——这里**不回写** `reminderEnabled`:开着 iCloud 时药品可能比它的任务
    /// 先同步到另一台设备,那时按"任务不在"去改数据会把提醒误关掉。下次保存这种药时按界面上的
    /// 开关重新对齐。
    static func reminderActive(_ med: Medication, context: ModelContext) -> Bool {
        guard med.reminderEnabled, !med.archived, let task = task(med.taskUUID, context: context) else {
            return false
        }
        return task.status == .pending
    }

    static func taskTitle(for med: Medication) -> String {
        let language = AppSettings.language
        let dosage = med.dosage.trimmingCharacters(in: .whitespaces)
        if dosage.isEmpty {
            return String(localized: "服药:\(med.name)", bundle: .appLanguage(), locale: language.locale)
        }
        return String(localized: "服药:\(med.name) \(dosage)", bundle: .appLanguage(), locale: language.locale)
    }

    private static func task(_ uuid: UUID?, context: ModelContext) -> TaskItem? {
        guard let uuid else { return nil }
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - 服药记录

    @discardableResult
    static func logDose(_ med: Medication, at date: Date = Date(), status: MedicationPlan.Status = .taken,
                        context: ModelContext) -> MedicationDose {
        let dose = MedicationDose(medicationUUID: med.uuid, name: med.name, dosage: med.dosage,
                                  takenAt: date, status: status, source: .manual)
        context.insert(dose)
        try? context.save()
        // 这一顿的提醒已经到点(或一小时内就到):手记这一笔就等于处理了它,提醒任务往下一顿走,
        // 不然通知还会接着响,再从通知点「完成」又多记一笔。
        if let task = task(med.taskUUID, context: context), task.status == .pending,
           task.remindAt <= date.addingTimeInterval(manualLogWindow) {
            advanceReminder(task, context: context)
        }
        return dose
    }

    /// 提醒任务往下一顿走:从**这一顿的原定时间**往后找(提前手记时不能按现在时刻算,
    /// 不然 07:30 记了 08:00 那顿,下一次还是今天 08:00)。不插已完成历史——手记那一笔就是记录。
    private static func advanceReminder(_ task: TaskItem, context: ModelContext) {
        guard let next = Scheduler.nextOccurrence(task.data, after: task.remindAt) else { return }
        task.remindAt = next
        task.nextRemindAt = next
        task.phaseRaw = TaskPhase.start.rawValue
        task.ignoreStreak = 0
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    /// 在别处(Apple Watch)完成的用药提醒:手表库里没有服药表,只留下带 medicationUUID 的
    /// 已完成历史。这里按最近 30 天的这类历史补记服药,30 分钟内已经有一笔的不重复记。
    static func backfillDosesFromHistory(context: ModelContext) {
        let since = Date().addingTimeInterval(-30 * 86400)
        let history = ((try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "done" && $0.medicationUUID != nil }))) ?? [])
            .filter { ($0.doneAt ?? .distantPast) >= since }
        guard !history.isEmpty else { return }
        let doses = (try? context.fetch(FetchDescriptor<MedicationDose>(
            predicate: #Predicate { $0.takenAt >= since }))) ?? []
        var existing = doses.map(\.entry)
        let meds = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        var added = false
        for item in history {
            guard let medID = item.medicationUUID, let doneAt = item.doneAt,
                  MedicationPlan.shouldImport(sampleID: "task:\(item.uuid.uuidString)", medicationID: medID,
                                              takenAt: doneAt, existing: existing) else { continue }
            let med = meds.first { $0.uuid == medID }
            let dose = MedicationDose(medicationUUID: medID, name: med?.name ?? item.title,
                                      dosage: med?.dosage ?? "", takenAt: doneAt, status: .taken,
                                      source: .task, taskUUID: item.uuid)
            context.insert(dose)
            existing.append(dose.entry)
            added = true
        }
        if added { try? context.save() }
    }

    /// 手记的那一笔离提醒任务的这一顿多近,就算处理了这一顿。
    static let manualLogWindow: TimeInterval = 60 * 60

    /// 完成了一条用药提醒任务:记一笔「已服用」。药已经删掉了就用任务标题当名字。
    static func logDose(fromTask task: TaskItem, context: ModelContext) {
        guard let medID = task.medicationUUID else { return }
        var descriptor = FetchDescriptor<Medication>(predicate: #Predicate { $0.uuid == medID })
        descriptor.fetchLimit = 1
        let med = try? context.fetch(descriptor).first
        let dose = MedicationDose(medicationUUID: medID, name: med?.name ?? task.title,
                                  dosage: med?.dosage ?? "", takenAt: Date(), status: .taken,
                                  source: .task, taskUUID: task.uuid)
        context.insert(dose)
    }

    /// 撤销「完成」时把那一下记的服药一起删掉。
    static func removeDoses(fromTask taskUUID: UUID, since date: Date, context: ModelContext) {
        let doses = (try? context.fetch(FetchDescriptor<MedicationDose>(
            predicate: #Predicate { $0.taskUUID == taskUUID }))) ?? []
        for dose in doses where dose.createdAt >= date {
            context.delete(dose)
        }
    }

    // MARK: - 健康 App(只读导入)

    /// 健康 App 里有、lodo 里还没对上的药。
    static func unlinkedHealthMedications(context: ModelContext) async -> [HealthKitBridge.HealthMedication] {
        let health = await HealthKitBridge.medications()
        let linked = Set(((try? context.fetch(FetchDescriptor<Medication>())) ?? []).compactMap(\.healthConceptID))
        return health.filter { !$0.archived && !linked.contains($0.id) }
    }

    /// 把健康 App 的一种药导进来:lodo 里有同名还没对上的就认领它,没有就新建一种(按需服用、不提醒)。
    @discardableResult
    static func importHealthMedication(_ item: HealthKitBridge.HealthMedication,
                                       context: ModelContext) -> Medication {
        let meds = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        let key = item.name.trimmingCharacters(in: .whitespaces).lowercased()
        if let same = meds.first(where: {
            $0.healthConceptID == nil && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key
        }) {
            same.healthConceptID = item.id
            try? context.save()
            return same
        }
        let med = Medication(name: item.name, healthConceptID: item.id)
        context.insert(med)
        try? context.save()
        return med
    }

    /// 把健康 App 最近 30 天的服药记录对上已认领的药,导进来(去重见 `MedicationPlan.shouldImport`)。
    /// 返回新导入了几笔。健康分析关着时不读。
    @discardableResult
    static func importHealthDoses(context: ModelContext) async -> Int {
        guard AppSettings.healthEnabled, HealthKitBridge.medicationsSupported else { return 0 }
        let meds = ((try? context.fetch(FetchDescriptor<Medication>())) ?? [])
        let byConcept = Dictionary(meds.compactMap { med in med.healthConceptID.map { ($0, med) } },
                                   uniquingKeysWith: { first, _ in first })
        guard !byConcept.isEmpty else { return 0 }
        let events = await HealthKitBridge.doseEvents(days: 30)
        guard !events.isEmpty else { return 0 }
        let since = Date().addingTimeInterval(-31 * 86400)
        let doses = (try? context.fetch(FetchDescriptor<MedicationDose>(
            predicate: #Predicate { $0.takenAt >= since }))) ?? []
        var existing = doses.map(\.entry)
        var imported = 0
        for event in events {
            guard let med = byConcept[event.conceptID],
                  MedicationPlan.shouldImport(sampleID: event.sampleID, medicationID: med.uuid,
                                              takenAt: event.date, existing: existing) else { continue }
            let quantity = event.quantity.map { $0.formatted(.number.precision(.fractionLength(0...2))) }
            let dose = MedicationDose(medicationUUID: med.uuid, name: med.name,
                                      dosage: quantity.map { med.dosage.isEmpty ? $0 : med.dosage } ?? med.dosage,
                                      takenAt: event.date, status: event.taken ? .taken : .skipped,
                                      source: .health, healthSampleID: event.sampleID)
            context.insert(dose)
            existing.append(dose.entry)
            imported += 1
        }
        if imported > 0 { try? context.save() }
        return imported
    }
}
