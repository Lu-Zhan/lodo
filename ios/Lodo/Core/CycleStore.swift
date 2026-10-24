import Foundation
import Observation
import SwiftData
import UserNotifications
import LodoCore

/// 经期:合并手记和健康 App 的记录、排经期提醒。纯逻辑在 `CyclePlan`。
///
/// 隐私口径:经期数据**不发给 AI**(不进 `read_health`、不进健康分析的汇总),
/// 健康 App 那一半只在健康分析或「与健康 App 同步」开着时才读,读也只读日子和档位;
/// 写回健康 App 只在开了同步时做(`CycleHealthSync`)。
@MainActor
enum CycleStore {
    static let reminderID = "cycle-reminder"
    /// 健康 App 往回读多少天(够算 6 个周期)。
    static let healthLookbackDays = 400
    static let reminderDaysBefore = 2

    /// 用户点「今天还没来 / 今天还没结束」:记下确认的那天,预测按它重新估计并重排提醒。
    static func confirmNotStarted(context: ModelContext) {
        CycleConfirmations.shared.notStartedThrough = Calendar.current.startOfDay(for: Date())
        rescheduleFromRecords(context: context)
    }

    static func confirmOngoing(context: ModelContext) {
        CycleConfirmations.shared.ongoingThrough = Calendar.current.startOfDay(for: Date())
        rescheduleFromRecords(context: context)
    }

    /// 撤销刚才的确认(按错了)。
    static func clearConfirmations(context: ModelContext) {
        CycleConfirmations.shared.notStartedThrough = nil
        CycleConfirmations.shared.ongoingThrough = nil
        rescheduleFromRecords(context: context)
    }

    /// 健康 App 里的经期(健康分析关着、这台设备没有健康库时为空)。
    static func healthPeriods() async -> [CyclePlan.Period] {
        await healthData().periods
    }

    /// 健康 App 里的经期段 + 每天的出血量档位(同一次查询)。只读,不落进手记表。
    static func healthData() async -> (periods: [CyclePlan.Period], flows: [CycleFlow.HealthSample]) {
        guard AppSettings.cycleReadsHealth, HealthKitBridge.isAvailable else { return ([], []) }
        // lodo 自己写回去的不算健康 App 的数据(手记那份已经在了)。
        let samples = (await HealthKitBridge.menstrualFlowSamples(days: healthLookbackDays) ?? [])
            .filter { !$0.fromLodo }
        let periods = CyclePlan.periods(fromFlowDays: samples.filter { $0.level.isBleeding }.map(\.date))
        let flows = samples.map { CycleFlow.HealthSample(dayKey: CycleFlow.dayKey($0.date), level: $0.level) }
        return (periods, flows)
    }

    // MARK: - 出血量

    /// 记某一天的出血量:那天已经有手记就改它(取最新那条,清过的也复用),没有就新建一条。
    /// 未来的日子不让记;查不出、存不进返回 false(界面上如实说,别假装记上了)。
    @discardableResult
    static func setFlow(_ level: CycleFlowLevel, on day: Date, context: ModelContext) -> Bool {
        guard Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: Date()) else { return false }
        let key = CycleFlow.dayKey(day)
        let now = Date()
        do {
            if let record = try latestFlow(on: key, context: context) {
                record.levelRaw = level.rawValue
                record.isDeleted = false
                record.updatedAt = now
            } else {
                context.insert(PeriodFlowRecord(dayKey: key, level: level, updatedAt: now))
            }
            try context.save()
            CycleHealthSync.shared.schedule(context: context)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    /// 清掉某一天的手记出血量:写墓碑(不删行),另一台设备上的旧副本不会让它复活。
    /// 那天本来就没有手记也算成功。
    @discardableResult
    static func clearFlow(on day: Date, context: ModelContext) -> Bool {
        guard Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: Date()) else { return false }
        do {
            guard let record = try latestFlow(on: CycleFlow.dayKey(day), context: context),
                  !record.isDeleted else { return true }
            record.isDeleted = true
            record.updatedAt = Date()
            try context.save()
            CycleHealthSync.shared.schedule(context: context)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private static func latestFlow(on key: String, context: ModelContext) throws -> PeriodFlowRecord? {
        let records = try context.fetch(FetchDescriptor<PeriodFlowRecord>(
            predicate: #Predicate { $0.dayKey == key }))
        return records.max { a, b in
            a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : a.uuid.uuidString < b.uuid.uuidString
        }
    }

    /// 「经期开始了」:今天开一段。今天已经开过就不重复开。
    ///
    /// 以前点了开始忘了点结束的那段**不替它写结束日**(原来按平均长度自动收尾,写进去就成了
    /// 用户确认过的结束,会混进经期天数的估计)。它留着「结束未确认」,合并时按平均长度收尾显示。
    @discardableResult
    static func startToday(records: [PeriodRecord], context: ModelContext) -> Bool {
        startPeriod(on: Date(), context: context)
    }

    /// 「经期结束了」:把最近那段还开着的收在今天(不管开了几天——过了预计范围的那段
    /// 用户点结束,就是它今天结束的意思)。
    static func endToday(records: [PeriodRecord], context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let open = records.filter({ $0.end == nil && $0.start <= today })
            .max(by: { $0.start < $1.start }) else { return }
        open.end = today
        try? context.save()
        rescheduleFromRecords(context: context)
    }

    /// 只有健康 App 里有这次经期、用户点了「经期结束了」:记一条手记(开始同健康 App、今天结束),
    /// 手记优先,合并时盖住健康 App 那段。健康 App 里的数据不改。
    static func endHealthPeriod(start: Date, context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = min(calendar.startOfDay(for: start), today)
        context.insert(PeriodRecord(start: startDay, end: today))
        try? context.save()
        rescheduleFromRecords(context: context)
    }

    /// 从某一天开一次经期(「经期开始了」、补记出血量时选了「记为开始」)。那天已经有开始
    /// 记录就不重复开(也算成功)。未来的日子、查不出、存不进返回 false。
    @discardableResult
    static func startPeriod(on day: Date, context: ModelContext) -> Bool {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: day)
        guard startDay <= calendar.startOfDay(for: Date()) else { return false }
        do {
            let records = try context.fetch(FetchDescriptor<PeriodRecord>())
            if records.contains(where: { calendar.isDate($0.start, inSameDayAs: startDay) }) { return true }
            context.insert(PeriodRecord(start: startDay))
            try context.save()
        } catch {
            context.rollback()
            return false
        }
        rescheduleFromRecords(context: context)
        return true
    }

    /// 按库里最新的手记 + 已经读来的健康 App 经期(`CycleHealthPeriods`,不再读一次)重排提醒。
    /// 每个写入点(开始/结束、补记、编辑、删除、切提醒开关)和读完健康数据之后都调它。
    static func rescheduleFromRecords(context: ModelContext) {
        // 写入点都会走到这里:顺带把手记同步回健康 App(没开同步时什么都不做)。
        CycleHealthSync.shared.schedule(context: context)
        guard AppSettings.cycleTrackingEnabled else {
            cancelReminder()
            return
        }
        // 关提醒不依赖健康数据:马上撤,不等读完。
        guard AppSettings.cycleReminderEnabled else {
            cancelReminder()
            return
        }
        // 健康 App 那一半还没读完:先不动已经排好的提醒,读完会再调这里。
        guard CycleHealthPeriods.shared.ready else {
            CycleHealthPeriods.shared.ensureLoading(context: context)
            return
        }
        let records = (try? context.fetch(FetchDescriptor<PeriodRecord>())) ?? []
        let now = Date()
        let periods = CyclePlan.merge(manual: records.map(\.period),
                                      health: CycleHealthPeriods.shared.periods, today: now)
        reschedule(prediction: periods.isEmpty ? nil : CyclePrediction.predict(
            periods, today: now, confirmations: CycleConfirmations.shared.value))
    }

    /// 按最新的预测重排经期提醒:预计范围下界前 2 天的全天提醒时刻。没开、依据不足
    /// (`CyclePrediction.canRemind`)、时刻已过都只撤不排。
    static func reschedule(prediction: CyclePrediction.Result?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard AppSettings.cycleTrackingEnabled, AppSettings.cycleReminderEnabled, let prediction,
              let next = prediction.nextStart,
              let fire = CyclePrediction.reminderDate(prediction, time: AppSettings.allDayTime, now: Date())
        else { return }
        let language = AppSettings.language
        let range = CycleText.range(next.lower, next.upper, locale: language.locale)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "经期提醒", bundle: .appLanguage(), locale: language.locale)
        content.body = String(localized: "预计 \(range) 可能来月经,记得备好用品。",
                              bundle: .appLanguage(), locale: language.locale)
        content.sound = .default
        content.userInfo = ["route": "health"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(
            identifier: reminderID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// 回前台时按最新数据重排一次(不依赖健康页开着)。**不自己读健康 App**:交给协调器按当前
    /// 设置重读(同一套代次 / 取消 / 开关复核),读完它会拿最新的手记统一重排。
    static func refreshReminder(context: ModelContext) async {
        guard AppSettings.cycleTrackingEnabled else {
            cancelReminder()
            return
        }
        CycleHealthPeriods.shared.reload(context: context)
    }

    /// 关掉经期功能时撤掉提醒。
    static func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}

/// 手记的经期 → 健康 App(「与健康 App 同步」开着时)。对账逻辑在 `CycleHealthExport`。
///
/// - **只动 lodo 自己写的样本**:健康 App 里用户自己 / 别的 app 记的一条不碰;那天已经有别的
///   来源记过就不再写(读的时候它们本来就会合并进来)。
/// - lodo 写的那份以手记为准:在健康 App 里删掉 lodo 写的某天,下次对账会补回来;要删就在
///   lodo 里改手记。
/// - 写入点调 `schedule`(合并 0.8 秒),回前台随重读健康数据后的重排再兜一次底。
/// - 关掉同步不删已经写进去的样本(那已经是用户健康记录的一部分)。
@MainActor
@Observable
final class CycleHealthSync {
    static let shared = CycleHealthSync()

    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        /// 没给写权限(到 设置 → 健康 → 数据访问与设备 里打开)。
        case notAuthorized
        case failed
    }

    private(set) var status: Status = .idle
    private var pending: Task<Void, Never>?
    private var running = false
    private var rerun = false

    func schedule(context: ModelContext) {
        guard AppSettings.cycleHealthSyncEnabled, AppSettings.cycleTrackingEnabled,
              HealthKitBridge.isAvailable else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.run(context: context)
        }
    }

    private func run(context: ModelContext) async {
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await syncOnce(context: context)
        } while rerun
    }

    private func syncOnce(context: ModelContext) async {
        guard AppSettings.cycleHealthSyncEnabled, AppSettings.cycleTrackingEnabled,
              HealthKitBridge.isAvailable else { return }
        guard HealthKitBridge.cycleWriteAuthorized else {
            status = .notAuthorized
            return
        }
        status = .syncing
        let lookback = CycleStore.healthLookbackDays
        // 查不到现状就不对账(当成空的会把每天重写一遍)。
        guard let samples = await HealthKitBridge.menstrualFlowSamples(days: lookback) else {
            status = .failed
            return
        }
        let calendar = Calendar.current
        let now = Date()
        let records = (try? context.fetch(FetchDescriptor<PeriodRecord>())) ?? []
        let flows = (try? context.fetch(FetchDescriptor<PeriodFlowRecord>())) ?? []
        let foreign = samples.filter { !$0.fromLodo }
        let foreignPeriods = CyclePlan.periods(fromFlowDays: foreign.filter { $0.level.isBleeding }.map(\.date))
        let merged = CyclePlan.merge(manual: records.map(\.period), health: foreignPeriods, today: now)
        let openLimit = merged.isEmpty ? CyclePlan.defaultPeriodLength
            : CyclePrediction.predict(merged, today: now, confirmations: CycleConfirmations.shared.value).periodLength
        // 窗口留一天余量:最早那天的样本可能只落了一半在查询范围里。
        let since = calendar.date(byAdding: .day, value: -(lookback - 1), to: now) ?? now
        let desired = CycleHealthExport.desired(
            manual: records.map(\.period), flows: flows.map(\.entry),
            foreignDays: Set(foreign.map { CycleFlow.dayKey($0.date) }),
            since: since, today: now, openLimit: openLimit)
        let existing = samples.filter { $0.fromLodo && $0.date >= calendar.startOfDay(for: since) }.map {
            CycleHealthExport.Existing(id: $0.id, day: .init(dayKey: CycleFlow.dayKey($0.date),
                                                             level: $0.level, isStart: $0.isStart))
        }
        let plan = CycleHealthExport.plan(desired: desired, existing: existing)
        var ok = true
        if !plan.delete.isEmpty { ok = await HealthKitBridge.deleteMenstrualFlow(ids: plan.delete) && ok }
        if !plan.add.isEmpty { ok = await HealthKitBridge.saveMenstrualFlow(plan.add) && ok }
        status = ok ? .synced(Date()) : .failed
    }
}

/// 「今天还没来 / 今天还没结束」的确认日(`CyclePrediction.Confirmations`)。
///
/// 存本机 UserDefaults(公历 "yyyy-MM-dd"),**不进 SwiftData、不同步、不备份**:它只在这几天里
/// 有意义,新的一次开始 / 记了结束日之后预测自己就不再认它(`CyclePrediction.predict` 里按最近
/// 一次开始核对),用不着清理。`@Observable` 让开着的页面跟着变。
@MainActor
@Observable
final class CycleConfirmations {
    static let shared = CycleConfirmations()
    static let notStartedKey = "cycleNotStartedThrough"
    static let ongoingKey = "cycleOngoingThrough"

    var notStartedThrough: Date? {
        didSet { Self.store(notStartedThrough, key: Self.notStartedKey) }
    }
    var ongoingThrough: Date? {
        didSet { Self.store(ongoingThrough, key: Self.ongoingKey) }
    }

    var value: CyclePrediction.Confirmations {
        CyclePrediction.Confirmations(notStartedThrough: notStartedThrough, ongoingThrough: ongoingThrough)
    }

    private init() {
        notStartedThrough = Self.load(Self.notStartedKey)
        ongoingThrough = Self.load(Self.ongoingKey)
    }

    private static func load(_ key: String) -> Date? {
        UserDefaults.standard.string(forKey: key).flatMap { CycleFlow.date(fromKey: $0) }
    }

    private static func store(_ date: Date?, key: String) {
        if let date {
            UserDefaults.standard.set(CycleFlow.dayKey(date), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
