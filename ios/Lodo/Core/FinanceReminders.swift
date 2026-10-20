import Foundation
import SwiftData
import LodoCore

/// 信用卡的账单日 / 还款日 / 年费提醒:每张卡每种开着的提醒,下一期生成一条普通任务
/// (「还信用卡:招商银行 经典白」「查看信用卡账单:…」「核对信用卡年费:…」),
/// 提醒时刻是目标日往前「提前天数」那天的全天提醒时刻(`CreditCardPlan.reminder`)。
///
/// 为什么是一条任务而不是单独排一个通知:任务就有纠缠式提醒(没点完成会按稍等间隔
/// 一直响),还款正是最不该"响一下就算了"的事;账单和年费默认关,打开了就是用户
/// 想被盯着看一眼。而且任务会出现在任务页、总览、日历同步里,和别的事排在一起看。
///
/// **任务提前建好、到时候才响**:不等到那一天才去生成——那天 app 没打开就漏了。
/// 每张卡每种提醒只追着"下一期"建一条,标记记在卡上(`FinanceEntry.reminderMark`);
/// 这一期的任务完成或删掉之后不再补,等目标日一过、下一期到来时再建下一条。
/// 年费例外:提醒时刻前 60 天内才建(一年后的事挂在任务列表里没有意义)。
@MainActor
enum FinanceReminders {
    /// 对账一遍全部信用卡。回前台、资产页打开、卡片保存/删除后都调。
    /// `edited` 是刚在表单里保存的(或别的成员经共享改了提醒设置的)卡:只有它们的当期提醒会按新的提前天数/日子重排——
    /// 别的时候对账不碰已经建好的任务的时间,用户在任务页或让 AI 改过期的不会被改回去。
    static func sync(context: ModelContext, edited: Set<UUID> = [], now: Date = .now) {
        let entries = (try? context.fetch(FetchDescriptor<FinanceEntry>())) ?? []
        var changed = false
        for card in entries where card.kind == .creditCard {
            for kind in CardReminderKind.allCases {
                changed = sync(card, kind: kind, retime: edited.contains(card.uuid), context: context, now: now)
                    || changed
            }
        }
        if changed {
            try? context.save()
            WidgetBridge.sync(context: context)
            CalendarSync.sync(context: context)
        }
    }

    /// 返回这次有没有动过数据。
    @discardableResult
    private static func sync(_ card: FinanceEntry, kind: CardReminderKind, retime: Bool,
                             context: ModelContext, now: Date) -> Bool {
        let mark = card.reminderMark(kind)
        let existing = mark.task.flatMap { task(uuid: $0, context: context) }
        let snapshot = card.snapshot
        guard CreditCardPlan.isActive(snapshot, kind: kind),
              let reminder = CreditCardPlan.reminder(for: snapshot, kind: kind,
                                                     allDayTime: AppSettings.allDayTime, now: now) else {
            // 关掉提醒 / 没填日子 / 改成免年费:我们建的、还没完成的那条撤掉(已经完成的是历史,留着)。
            guard mark.task != nil || !mark.cycle.isEmpty else { return false }
            if let existing, existing.status == .pending { TaskActions.delete(existing, context: context) }
            card.setReminderMark(kind, cycle: "", task: nil)
            return true
        }
        let title = taskTitle(for: card, kind: kind)
        if mark.cycle == reminder.cycle {
            // 这一期已经建过。用户完成或删掉了就不再补;还挂着的跟着卡片改名,
            // 还没响过的跟着提前天数/全天提醒时刻改时间。
            guard let existing, existing.status == .pending else { return false }
            var changed = false
            if existing.title != title {
                existing.title = title
                changed = true
            }
            // 新的提醒时刻已经过了(提前天数改大了)就取 now,马上响,而不是等原来那一刻。
            if retime, existing.remindAt > now, existing.remindAt != reminder.remindAt {
                TaskActions.apply(parsed(title, at: reminder.remindAt), to: existing, context: context)
                changed = true
            }
            return changed
        }
        // 年费:离提醒还远,先不建。原来那条还没响(改了收取日期)就撤掉,别按旧日子响。
        guard now >= reminder.createAfter else {
            guard retime, let existing, existing.status == .pending, existing.remindAt > now else { return false }
            TaskActions.delete(existing, context: context)
            card.setReminderMark(kind, cycle: "", task: nil)
            return true
        }
        let task = parsed(title, at: reminder.remindAt)
        // 上一条还挂着、提醒时刻还没到:多半是改了日子,原地改成新的一期,不另建一条。
        if let existing, existing.status == .pending, existing.remindAt > now {
            TaskActions.apply(task, to: existing, context: context)
            card.setReminderMark(kind, cycle: reminder.cycle, task: existing.uuid)
        } else {
            let created = TaskActions.create(task, context: context)
            card.setReminderMark(kind, cycle: reminder.cycle, task: created.uuid)
        }
        return true
    }

    private static func parsed(_ title: String, at date: Date) -> ParsedTask {
        ParsedTask(title: title, remindAt: date, allDay: false, repeatType: .none,
                   repeatDays: [], repeatTimes: [])
    }

    /// 删卡片时调:它建的、还没完成的提醒(三种)一起撤掉(卡都没了,提醒只会让人困惑)。
    static func removeReminder(for card: FinanceEntry, context: ModelContext) {
        for kind in CardReminderKind.allCases {
            guard let uuid = card.reminderMark(kind).task, let existing = task(uuid: uuid, context: context),
                  existing.status == .pending else { continue }
            TaskActions.delete(existing, context: context)
        }
    }

    static func taskTitle(for card: FinanceEntry, kind: CardReminderKind = .repayment) -> String {
        let name = [card.institution, card.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, part in
                // 「招商银行」+「招商银行信用卡」别拼成两遍。
                if !result.contains(where: { $0.contains(part) || part.contains($0) }) { result.append(part) }
            }
            .joined(separator: " ")
        let locale = AppSettings.language.locale
        switch kind {
        case .repayment:
            return String(localized: "还信用卡:\(name)", bundle: .appLanguage(), locale: locale)
        case .statement:
            return String(localized: "查看信用卡账单:\(name)", bundle: .appLanguage(), locale: locale)
        case .annualFee:
            return String(localized: "核对信用卡年费:\(name)", bundle: .appLanguage(), locale: locale)
        }
    }

    private static func task(uuid: UUID, context: ModelContext) -> TaskItem? {
        ((try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uuid == uuid }))) ?? [])
            .first
    }
}
