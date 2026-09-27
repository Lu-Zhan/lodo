import Foundation
import SwiftData
import UserNotifications
import LodoCore

/// 倒数日的展示文案。页面、锁屏小组件快照、通知共用这一份,都按应用内语言出
/// (`String(localized:locale:)`,同 ContactListView 的「(未命名)」写法),
/// 字符串目录里的 key 就是这里的中文原文。
enum CountdownText {
    private static var locale: Locale { AppSettings.language.locale }

    /// 主文案:"还有 12 天""还有 3 小时 20 分钟""就是今天""已结束 2 天"……
    /// `hasEnd` 区分"开始"措辞——只有一个日子的事(生日、考试)说"还有 12 天"
    /// 就够了,硬加"开始"读着别扭。`precise` = false 时不报小时分钟(小组件一天
    /// 只刷新几次,"还有 3 小时"挂一下午就是错的),当天统一说"今天"。
    static func text(_ span: CountdownSpan, hasEnd: Bool, precise: Bool = true) -> String {
        let minutes = precise ? span.minutes : nil
        switch span.milestone {
        case .untilStart:
            if let minutes, span.days == 0 {
                if minutes < 1 { return String(localized: "马上开始", locale: locale) }
                let duration = durationText(minutes)
                return hasEnd ? String(localized: "还有 \(duration)开始", locale: locale)
                    : String(localized: "还有 \(duration)", locale: locale)
            }
            if span.days == 0 {
                return hasEnd ? String(localized: "今天开始", locale: locale)
                    : String(localized: "就是今天", locale: locale)
            }
            return hasEnd ? String(localized: "还有 \(span.days) 天开始", locale: locale)
                : String(localized: "还有 \(span.days) 天", locale: locale)
        case .sinceStart:
            if span.days == 0 {
                if let minutes, !hasEnd {
                    return minutes < 1 ? String(localized: "就是现在", locale: locale)
                        : String(localized: "已过去 \(durationText(minutes))", locale: locale)
                }
                return hasEnd ? String(localized: "今天开始", locale: locale)
                    : String(localized: "就是今天", locale: locale)
            }
            return hasEnd ? String(localized: "已开始 \(span.days) 天", locale: locale)
                : String(localized: "已过去 \(span.days) 天", locale: locale)
        case .untilEnd:
            if let minutes, span.days == 0 {
                return minutes < 1 ? String(localized: "马上结束", locale: locale)
                    : String(localized: "还有 \(durationText(minutes))结束", locale: locale)
            }
            if span.days == 0 { return String(localized: "今天结束", locale: locale) }
            return String(localized: "还有 \(span.days) 天结束", locale: locale)
        case .sinceEnd:
            if span.days == 0 { return String(localized: "刚刚结束", locale: locale) }
            return String(localized: "已结束 \(span.days) 天", locale: locale)
        }
    }

    /// "3 小时 20 分钟" / "45 分钟" / "2 小时"。
    static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) 分钟", locale: locale) }
        if rest == 0 { return String(localized: "\(hours) 小时", locale: locale) }
        return String(localized: "\(hours) 小时 \(rest) 分钟", locale: locale)
    }

    /// 提醒选项的名字:准时 / 提前 5 分钟 / 提前 1 小时 / 提前 2 天 / 提前 1 周。
    static func offsetText(_ minutes: Int) -> String {
        switch minutes {
        case 0: return String(localized: "准时", locale: locale)
        case let m where m % 10080 == 0:
            return String(localized: "提前 \(m / 10080) 周", locale: locale)
        case let m where m % 1440 == 0:
            return String(localized: "提前 \(m / 1440) 天", locale: locale)
        case let m where m % 60 == 0:
            return String(localized: "提前 \(m / 60) 小时", locale: locale)
        default:
            return String(localized: "提前 \(minutes) 分钟", locale: locale)
        }
    }

    /// 表单里那一行的摘要:"准时、提前 1 天";一个都没选时"不提醒"。
    static func offsetsSummary(_ offsets: [Int]) -> String {
        let sorted = Array(Set(offsets)).sorted()
        guard !sorted.isEmpty else { return String(localized: "不提醒", locale: locale) }
        return sorted.map(offsetText).joined(separator: String(localized: "、", locale: locale))
    }

    /// 起讫时间:全天只写日期,有时刻的带时刻。
    static func dateText(_ date: Date, allDay: Bool) -> String {
        let format: Date.FormatStyle = allDay
            ? .dateTime.year().month().day().weekday()
            : .dateTime.year().month().day().weekday().hour().minute()
        return date.formatted(format.locale(locale))
    }
}

/// 倒数日提醒:把所有倒数日的下几次提醒排成本地通知。
///
/// 系统一共只给 64 条待发通知,纠缠链占 48、定时任务兜底占 6、汇总还要几条,
/// 所以这里只排**最近的 `budget` 条**,每次改动/回前台重排一遍——远的那些
/// 等近的发完、下一次重排时自然轮上。和 RoutineRunner 的兜底通知同一个写法。
@MainActor
enum CountdownNotifier {
    static let prefix = "countdown-"
    static let budget = 5

    static func reschedule(context: ModelContext) {
        let events = (try? context.fetch(FetchDescriptor<CountdownEvent>())) ?? []
        let reminders = CountdownPlan.reminders(events.map(\.entry),
                                                allDayTime: AppSettings.allDayTime, now: Date())
        let planned = Array(reminders.prefix(budget))
        let byID = Dictionary(events.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        // 只把字符串和时间带进回调(通知内容对象不是 Sendable),在回调里再组装。
        let slots: [(id: String, title: String, body: String, uuid: String, date: Date)] =
            planned.enumerated().map { index, reminder in
                var body = ""
                if let event = byID[reminder.eventID] {
                    let entry = event.entry
                    // 通知里的那句按"提醒响起的那一刻"算,而不是按现在算。
                    body = CountdownText.text(CountdownPlan.primary(entry, now: reminder.fireDate),
                                              hasEnd: entry.end != nil)
                }
                let title = reminder.title.isEmpty
                    ? String(localized: "倒数日", locale: AppSettings.language.locale)
                    : reminder.title
                return ("\(prefix)\(index)", title, body, reminder.eventID.uuidString,
                        reminder.fireDate)
            }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for slot in slots {
                let content = UNMutableNotificationContent()
                content.title = slot.title
                content.body = slot.body
                content.sound = .default
                content.userInfo = ["countdownUUID": slot.uuid]
                center.add(UNNotificationRequest(
                    identifier: slot.id, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: max(1, slot.date.timeIntervalSinceNow), repeats: false)))
            }
        }
    }
}

/// AI 对倒数日的操作(`CountdownOp`)落库与撤销。和 `TravelStore.applyEdit`/`revertEdit`
/// 同一个路子:执行时把新建的 uuid、改之前的整份快照记进 `CountdownEditRecord`,
/// 撤销就照着记录删掉新建的、把改过和删掉的写回原样。
@MainActor
enum CountdownStore {
    static func apply(_ ops: [CountdownOp], context: ModelContext) -> CountdownEditRecord {
        var record = CountdownEditRecord()
        let calendar = Calendar.current
        let all = (try? context.fetch(FetchDescriptor<CountdownEvent>())) ?? []
        var widgetCount = all.filter(\.showInWidget).count
        func find(_ id: UUID) -> CountdownEvent? { all.first { $0.uuid == id } }
        /// 小组件满了就不放,记进 skipped 如实说。
        func widgetAllowed(_ wanted: Bool, title: String, already: Bool) -> Bool {
            guard wanted, !already else { return wanted }
            guard widgetCount < CountdownPlan.widgetLimit else {
                record.skipped.append(String(localized: "「\(title)」没放上小组件(最多 3 件)",
                                             locale: AppSettings.language.locale))
                return false
            }
            widgetCount += 1
            return true
        }

        for op in ops {
            switch op {
            case .create(let draft):
                let event = CountdownEvent(
                    title: draft.title,
                    startDate: draft.allDay ? calendar.startOfDay(for: draft.start) : draft.start,
                    endDate: draft.end.map { draft.allDay ? calendar.startOfDay(for: $0) : $0 },
                    allDay: draft.allDay, notes: draft.notes,
                    startReminders: draft.startReminders, endReminders: draft.endReminders)
                event.showInWidget = widgetAllowed(draft.showInWidget ?? false,
                                                   title: draft.title, already: false)
                context.insert(event)
                record.created.append(event.backup)
            case .update(let id, let change):
                guard let event = find(id) else {
                    record.skipped.append(String(localized: "有一个倒数日没找到",
                                                 locale: AppSettings.language.locale))
                    continue
                }
                record.updatedBefore.append(event.backup)
                if let title = change.title { event.title = title }
                if let allDay = change.allDay { event.allDay = allDay }
                if let start = change.start {
                    event.startDate = event.allDay ? calendar.startOfDay(for: start) : start
                }
                switch change.end {
                case .set(let end)?:
                    event.endDate = event.allDay ? calendar.startOfDay(for: end) : end
                case .clear?:
                    event.endDate = nil
                    event.endReminders = []
                case nil:
                    break
                }
                // 只挪了开始、结束落到了开始前面:保持原来的跨度。
                if let before = record.updatedBefore.last, change.start != nil, change.end == nil,
                   let end = event.endDate, end < event.startDate, let oldEnd = before.endDate {
                    event.endDate = event.startDate.addingTimeInterval(
                        oldEnd.timeIntervalSince(before.startDate))
                }
                if let reminders = change.startReminders { event.startReminders = reminders }
                if let reminders = change.endReminders, event.endDate != nil {
                    event.endReminders = reminders
                }
                if let notes = change.notes { event.notes = notes }
                if let show = change.showInWidget {
                    if !show, event.showInWidget { widgetCount -= 1 }
                    event.showInWidget = widgetAllowed(show, title: event.title,
                                                       already: event.showInWidget)
                }
                record.updatedAfter.append(event.backup)
            case .delete(let id):
                guard let event = find(id) else {
                    record.skipped.append(String(localized: "有一个倒数日没找到",
                                                 locale: AppSettings.language.locale))
                    continue
                }
                record.deleted.append(event.backup)
                context.delete(event)
            }
        }
        finish(context)
        return record
    }

    static func revert(_ record: CountdownEditRecord, context: ModelContext) -> CountdownEditRecord {
        let all = (try? context.fetch(FetchDescriptor<CountdownEvent>())) ?? []
        let createdIDs = Set(record.created.map(\.uuid))
        for event in all where createdIDs.contains(event.uuid) {
            context.delete(event)
        }
        for snapshot in record.updatedBefore {
            if let event = all.first(where: { $0.uuid == snapshot.uuid }) {
                snapshot.apply(to: event)
            }
        }
        for snapshot in record.deleted {
            let event = CountdownEvent(uuid: snapshot.uuid)
            snapshot.apply(to: event)
            context.insert(event)
        }
        finish(context)
        var result = record
        result.reverted = true
        return result
    }

    private static func finish(_ context: ModelContext) {
        try? context.save()
        CountdownNotifier.reschedule(context: context)
        WidgetBridge.sync(context: context)
    }
}
