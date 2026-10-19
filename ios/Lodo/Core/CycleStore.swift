import Foundation
import SwiftData
import UserNotifications
import LodoCore

/// 经期:合并手记和健康 App 的记录、排经期提醒。纯逻辑在 `CyclePlan`。
///
/// 隐私口径:经期数据**不发给 AI**(不进 `read_health`、不进健康分析的汇总),
/// 健康 App 那一半只在健康分析开着时才读,读也只读日子、不读流量档位以外的东西。
@MainActor
enum CycleStore {
    static let reminderID = "cycle-reminder"
    /// 健康 App 往回读多少天(够算 6 个周期)。
    static let healthLookbackDays = 400
    static let reminderDaysBefore = 2

    /// 健康 App 里的经期(健康分析关着、这台设备没有健康库时为空)。
    static func healthPeriods() async -> [CyclePlan.Period] {
        guard AppSettings.healthEnabled, HealthKitBridge.isAvailable else { return [] }
        let days = await HealthKitBridge.menstrualFlowDays(days: healthLookbackDays)
        return CyclePlan.periods(fromFlowDays: days)
    }

    /// 「经期开始了」:今天开一段;已经有一段还没结束就不重复开。
    static func startToday(records: [PeriodRecord], context: ModelContext) {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if records.contains(where: { CyclePlan.isOpen(start: $0.start, end: $0.end, today: now) }) { return }
        // 以前点了开始忘了点结束、已经超期的那几段:按平均经期长度替它收尾。
        let average = CyclePlan.summary(records.map(\.period), today: now).averagePeriod
            ?? CyclePlan.defaultPeriodLength
        for stale in records where stale.end == nil && stale.start < today {
            stale.end = CyclePlan.effectiveEnd(stale.period, today: now, averagePeriod: average)
        }
        context.insert(PeriodRecord(start: today))
        try? context.save()
        rescheduleFromRecords(context: context)
    }

    /// 「经期结束了」:把还开着的那段收在今天。
    static func endToday(records: [PeriodRecord], context: ModelContext) {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        guard let open = records.filter({ CyclePlan.isOpen(start: $0.start, end: $0.end, today: now) })
            .max(by: { $0.start < $1.start }) else { return }
        open.end = today
        try? context.save()
        rescheduleFromRecords(context: context)
    }

    /// 按库里最新的手记 + 已经读来的健康 App 经期(`CycleHealthPeriods`,不再读一次)重排提醒。
    /// 每个写入点(开始/结束、补记、编辑、删除、切提醒开关)和读完健康数据之后都调它。
    static func rescheduleFromRecords(context: ModelContext) {
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
        reschedule(summary: periods.isEmpty ? nil : CyclePlan.summary(periods, today: now))
    }

    /// 按最新的预测重排经期提醒(没开、估不准、已在经期里都撤掉)。
    static func reschedule(summary: CyclePlan.Summary?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        guard AppSettings.cycleTrackingEnabled, AppSettings.cycleReminderEnabled, let summary,
              let fire = CyclePlan.reminderDate(summary, daysBefore: reminderDaysBefore,
                                                time: AppSettings.allDayTime, now: Date()) else { return }
        let language = AppSettings.language
        let content = UNMutableNotificationContent()
        content.title = String(localized: "经期提醒", bundle: .appLanguage(), locale: language.locale)
        content.body = String(localized: "预计 \(reminderDaysBefore) 天后来月经,记得备好用品。",
                              bundle: .appLanguage(), locale: language.locale)
        content.sound = .default
        content.userInfo = ["route": "health"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(
            identifier: reminderID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// 回前台时按最新记录重排一次(不依赖健康页开着)。
    static func refreshReminder(context: ModelContext) async {
        guard AppSettings.cycleTrackingEnabled else {
            cancelReminder()
            return
        }
        let records = (try? context.fetch(FetchDescriptor<PeriodRecord>())) ?? []
        let now = Date()
        let periods = CyclePlan.merge(manual: records.map(\.period), health: await healthPeriods(), today: now)
        reschedule(summary: periods.isEmpty ? nil : CyclePlan.summary(periods, today: now))
    }

    /// 关掉经期功能时撤掉提醒。
    static func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}
