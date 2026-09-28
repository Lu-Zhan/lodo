import Foundation
import SwiftData
import LodoCore

/// 信用卡还款提醒:每张开了提醒的卡,下一期的还款日**前一天**生成一条普通任务
/// (「还信用卡:招商银行 经典白」),提醒时刻是那天的全天提醒时刻。
///
/// 为什么是一条任务而不是单独排一个通知:任务就有纠缠式提醒(没点完成会按稍等间隔
/// 一直响),还款正是最不该"响一下就算了"的事;而且它会出现在任务页、总览、日历
/// 同步里,和别的事排在一起看。
///
/// **任务提前建好、到时候才响**(判据见 `FinancePlan.reminder`):不等到前一天才去
/// 生成——那天 app 没打开就漏了。每张卡只追着"下一期"建一条,标记记在卡上
/// (`reminderCycle`/`reminderTaskUUID`);这一期的任务完成或删掉之后,等还款日一过、
/// 下一期到来时再建下一条。
@MainActor
enum FinanceReminders {
    /// 对账一遍全部信用卡。回前台、资产页打开、卡片保存/删除后都调。
    static func sync(context: ModelContext, now: Date = .now) {
        let entries = (try? context.fetch(FetchDescriptor<FinanceEntry>())) ?? []
        var changed = false
        for card in entries where card.kind == .creditCard {
            changed = sync(card, context: context, now: now) || changed
        }
        if changed {
            try? context.save()
            WidgetBridge.sync(context: context)
            CalendarSync.sync(context: context)
        }
    }

    /// 返回这次有没有动过数据。
    @discardableResult
    private static func sync(_ card: FinanceEntry, context: ModelContext, now: Date) -> Bool {
        let existing = card.reminderTaskUUID.flatMap { task(uuid: $0, context: context) }
        guard card.remindEnabled,
              let reminder = FinancePlan.reminder(for: card.snapshot, allDayTime: AppSettings.allDayTime,
                                                  now: now) else {
            // 关掉提醒 / 没填还款日:我们建的、还没完成的那条撤掉(已经完成的是历史,留着)。
            guard let existing, existing.status == .pending else { return false }
            TaskActions.delete(existing, context: context)
            card.reminderTaskUUID = nil
            card.reminderCycle = ""
            return true
        }
        let title = taskTitle(for: card)
        if card.reminderCycle == reminder.cycle {
            // 这一期已经建过。卡片改了名字就把还没完成的那条跟着改名;用户完成或删掉了就不再补。
            if let existing, existing.status == .pending, existing.title != title {
                existing.title = title
                return true
            }
            return false
        }
        let parsed = ParsedTask(title: title, remindAt: reminder.remindAt, allDay: false,
                                durationMinutes: 0, repeatType: .none, repeatDays: [],
                                repeatTimes: [])
        // 上一条还挂着、提醒时刻还没到:多半是改了还款日,原地改成新的一期,不另建一条。
        if let existing, existing.status == .pending, existing.remindAt > now {
            TaskActions.apply(parsed, to: existing, context: context)
        } else {
            let created = TaskActions.create(parsed, context: context)
            card.reminderTaskUUID = created.uuid
        }
        card.reminderCycle = reminder.cycle
        return true
    }

    /// 删卡片时调:它建的、还没完成的那条提醒一起撤掉(卡都没了,还款提醒只会让人困惑)。
    static func removeReminder(for card: FinanceEntry, context: ModelContext) {
        guard let uuid = card.reminderTaskUUID, let existing = task(uuid: uuid, context: context),
              existing.status == .pending else { return }
        TaskActions.delete(existing, context: context)
    }

    static func taskTitle(for card: FinanceEntry) -> String {
        let name = [card.institution, card.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, part in
                // 「招商银行」+「招商银行信用卡」别拼成两遍。
                if !result.contains(where: { $0.contains(part) || part.contains($0) }) { result.append(part) }
            }
            .joined(separator: " ")
        return String(localized: "还信用卡:\(name)", bundle: .appLanguage(),
                      locale: AppSettings.language.locale)
    }

    private static func task(uuid: UUID, context: ModelContext) -> TaskItem? {
        ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uuid == uuid }))) ?? [])
            .first
    }
}
