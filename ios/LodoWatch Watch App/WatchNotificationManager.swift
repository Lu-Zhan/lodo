import Foundation
import SwiftData
import UserNotifications
import LodoCore

/// 纠缠式提醒的通知层,watchOS 版本。
///
/// 逻辑与 iOS `NotificationManager` 一致(预排通知链、稍等间隔、完成/重复顺延),
/// 独立于手机排自己的提醒——这正是选 CloudKit 而不是 WatchConnectivity 中转的意义:
/// 手机不在身边时 Watch 也能正常提醒。iPhone 和 Watch 会各自独立排同一个事项的提醒,
/// 如果两台设备都在身边可能都会响,这是可接受的多设备行为,不专门消除。
/// 精简自 iOS 版:不含每日汇总、AI 个性文案、改期动作(这些不是 Watch 的基础功能)。
final class WatchNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationManager()

    static let nagCategory = "LODO_NAG"
    static let doneAction = "LODO_DONE"
    static let snoozeAction = "LODO_SNOOZE"
    private static let chainLength = 8
    private static let chainBudget = 48

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.doneAction, title: "完成", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "稍等一会", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.nagCategory, actions: [done, snooze],
                                   intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 通知链

    @MainActor
    func rebuild(for task: TaskItem, chainLength: Int = WatchNotificationManager.chainLength) {
        let center = UNUserNotificationCenter.current()
        cancelChain(for: task.uuid)
        guard task.status == .pending else { return }

        let interval = TimeInterval(AppSettings.snoozeMinutes * 60)
        let now = Date()
        var anchor = task.nextRemindAt
        if anchor <= now {
            let missed = (now.timeIntervalSince(anchor) / interval).rounded(.down) + 1
            anchor = anchor.addingTimeInterval(missed * interval)
        }
        let starting = task.phase == .start && task.durationMinutes > 0
        for i in 0..<min(chainLength, Self.chainLength) {
            let fire = anchor.addingTimeInterval(interval * Double(i))
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = Self.reminderBody(starting: starting, isEnd: task.phase == .end,
                                             durationMinutes: task.durationMinutes)
            content.sound = .default
            content.categoryIdentifier = Self.nagCategory
            content.userInfo = ["uuid": task.uuid.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fire.timeIntervalSince(now), repeats: false)
            center.add(UNNotificationRequest(
                identifier: "watch-task-\(task.uuid.uuidString)-nag-\(i)",
                content: content, trigger: trigger))
        }
    }

    private static func reminderBody(starting: Bool, isEnd: Bool, durationMinutes: Int) -> String {
        if starting { return "该开始了!(时长 \(durationMinutes) 分钟)" }
        if isEnd { return "时间到 — 完成了吗?" }
        return "到时间了"
    }

    func cancelChain(for uuid: UUID) {
        let ids = (0..<Self.chainLength).map { "watch-task-\(uuid.uuidString)-nag-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 重排全部待办的通知链(app 启动/回到前台时调用);按全局预算分配,
    /// 避免 8 条 × N 任务撞系统上限导致后续提醒静默丢失。
    @MainActor
    func refreshAll() {
        guard let context = container?.mainContext else { return }
        var pending = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        pending.sortBy = [SortDescriptor(\.nextRemindAt)]
        let tasks = (try? context.fetch(pending)) ?? []
        var budget = Self.chainBudget - tasks.count
        for task in tasks {
            let extra = max(0, min(Self.chainLength - 1, budget))
            budget -= extra
            rebuild(for: task, chainLength: 1 + extra)
        }
    }

    // MARK: - 响应处理(通知按钮与 app 内按钮共用)

    @MainActor
    func complete(_ task: TaskItem, context: ModelContext) {
        var d = task.data
        let finished = Scheduler.advance(&d, now: Date())
        task.apply(d)
        if finished && d.status == .pending {
            context.insert(TaskItem(title: d.title, remindAt: Date(),
                                    status: .done, doneAt: Date()))
        }
        try? context.save()
        if task.status == .done {
            cancelChain(for: task.uuid)
        } else {
            rebuild(for: task)
        }
    }

    @MainActor
    func snooze(_ task: TaskItem, context: ModelContext) {
        var d = task.data
        Scheduler.snooze(&d, now: Date(), snoozeMinutes: AppSettings.snoozeMinutes)
        task.apply(d)
        try? context.save()
        rebuild(for: task)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        guard let uuidString = userInfo["uuid"] as? String,
              let uuid = UUID(uuidString: uuidString) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            defer { completionHandler() }
            guard let context = self.container?.mainContext else { return }
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            guard let task = try? context.fetch(descriptor).first,
                  task.status == .pending else { return }
            switch actionID {
            case Self.doneAction:
                self.complete(task, context: context)
            case Self.snoozeAction:
                self.snooze(task, context: context)
            default:
                break
            }
        }
    }
}
