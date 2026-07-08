import Foundation
import EventKit
import SwiftData
import LodoCore

/// 系统「提醒事项」(Apple Reminders) 连接层:权限、读取、导入、导出。
@MainActor
@Observable
final class RemindersBridge {
    static let shared = RemindersBridge()

    private let store = EKEventStore()
    var authStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    var systemReminders: [EKReminder] = []
    var lastError: String?

    var hasAccess: Bool { authStatus == .fullAccess }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            lastError = "请求权限失败:\(error.localizedDescription)"
        }
        authStatus = EKEventStore.authorizationStatus(for: .reminder)
        if hasAccess { await refresh() }
    }

    /// 读取系统里全部未完成的提醒事项。
    func refresh() async {
        guard hasAccess else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        systemReminders = found.sorted {
            ($0.dueDateComponents?.date ?? .distantFuture)
                < ($1.dueDateComponents?.date ?? .distantFuture)
        }
    }

    /// 把一条系统提醒事项导入为 lodo 事项。
    /// 有具体时间→定时事项;仅日期→全天;无日期→今天的全天事项。
    func importReminder(_ reminder: EKReminder, into context: ModelContext) {
        let task: TaskItem
        if let due = reminder.dueDateComponents, due.hour != nil,
           let date = Calendar.current.date(from: due) {
            task = TaskItem(title: reminder.title ?? "未命名", remindAt: date,
                            ekIdentifier: reminder.calendarItemIdentifier)
        } else {
            let day = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date()
            let remindAt = AppSettings.time(AppSettings.allDayTime, on: day)
            task = TaskItem(title: reminder.title ?? "未命名", remindAt: remindAt,
                            allDay: true, ekIdentifier: reminder.calendarItemIdentifier)
        }
        context.insert(task)
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    /// 把 lodo 事项导出/更新到系统提醒事项默认列表。
    /// 重复/多时间点事项导出下一次发生的那条(系统侧不支持完整语义)。
    func export(_ task: TaskItem) {
        lastError = nil
        let reminder: EKReminder
        if let id = task.ekIdentifier,
           let existing = store.calendarItem(withIdentifier: id) as? EKReminder {
            reminder = existing
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
        } else {
            reminder = EKReminder(eventStore: store)
            reminder.calendar = store.defaultCalendarForNewReminders()
        }
        reminder.title = task.title
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: task.nextRemindAt)
        reminder.addAlarm(EKAlarm(absoluteDate: task.nextRemindAt))
        if task.isRecurring {
            reminder.notes = "lodo 重复事项:\(task.data.repeatLabel)(系统侧仅显示下一次)"
        }
        do {
            try store.save(reminder, commit: true)
            task.ekIdentifier = reminder.calendarItemIdentifier
        } catch {
            lastError = "导出失败:\(error.localizedDescription)"
        }
    }
}
