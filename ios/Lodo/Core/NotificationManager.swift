import Foundation
import SwiftData
import UserNotifications
import LodoCore

/// 纠缠式提醒的通知层。
///
/// app 无法在后台跑定时器,因此为每个待办**预排一条通知链**:
/// nextRemindAt、+间隔、+2×间隔 … 共 8 条;用户点"完成"取消整链,
/// 点"稍等"或在 app 内响应则重排。忽略通知时,链上的后续通知自然实现反复提醒。
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let nagCategory = "LODO_NAG"
    static let doneAction = "LODO_DONE"
    static let snoozeAction = "LODO_SNOOZE"
    static let digestID = "lodo-digest"
    private static let chainLength = 8

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.doneAction, title: "完成",
                                        options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "稍等一会",
                                          options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.nagCategory, actions: [done, snooze],
                                   intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 通知链

    /// 取消并重排某事项的通知链,并同步小组件快照。
    @MainActor
    func rebuild(for task: TaskItem) {
        if let context = container?.mainContext {
            WidgetBridge.sync(context: context)
        }
        let center = UNUserNotificationCenter.current()
        cancelChain(for: task.uuid)
        guard task.status == .pending else { return }

        let interval = TimeInterval(AppSettings.snoozeMinutes * 60)
        let now = Date()
        // 已过期的事项把链锚定到下一个未来的稍等槽位,否则 8 条全落在过去,
        // 纠缠提醒会静默断链(数据库 nextRemindAt 保持过去值,app 内到期卡片不受影响)。
        var anchor = task.nextRemindAt
        if anchor <= now {
            let missed = (now.timeIntervalSince(anchor) / interval).rounded(.down) + 1
            anchor = anchor.addingTimeInterval(missed * interval)
        }
        let starting = task.phase == .start && task.durationMinutes > 0
        for i in 0..<Self.chainLength {
            let fire = anchor.addingTimeInterval(interval * Double(i))
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            if starting {
                content.body = "该开始了!(时长 \(task.durationMinutes) 分钟)"
            } else if task.phase == .end {
                content.body = "时间到 — 完成了吗?"
            } else {
                content.body = "到时间了"
            }
            content.sound = .default
            content.categoryIdentifier = Self.nagCategory
            content.userInfo = ["uuid": task.uuid.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fire.timeIntervalSince(now), repeats: false)
            center.add(UNNotificationRequest(
                identifier: "task-\(task.uuid.uuidString)-nag-\(i)",
                content: content, trigger: trigger))
        }
    }

    func cancelChain(for uuid: UUID) {
        let ids = (0..<Self.chainLength).map { "task-\(uuid.uuidString)-nag-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 重排全部待办的通知链和每日汇总(app 启动/回到前台时调用)。
    @MainActor
    func refreshAll() {
        guard let context = container?.mainContext else { return }
        let pending = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        let tasks = (try? context.fetch(pending)) ?? []
        for task in tasks { rebuild(for: task) }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        let todayTitles = tasks
            .filter { $0.nextRemindAt < endOfToday }
            .sorted { $0.nextRemindAt < $1.nextRemindAt }
            .map(\.title)
        updateDigest(todayTitles: todayTitles)
        WidgetBridge.sync(context: context)
    }

    /// 待办汇总:按设置的时间点与重复方式(每天/每周选中周几)排系统重复通知,
    /// 内容为今天开始或到期的事项(含已过期;app 进前台时刷新快照)。
    func updateDigest(todayTitles: [String]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            // 时间点/周几数量会变,按前缀清掉旧的(含老版本的单条 id)
            let old = requests.map(\.identifier).filter { $0.hasPrefix(Self.digestID) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard AppSettings.digestEnabled else { return }

            let content = UNMutableNotificationContent()
            content.title = "每日待办汇总"
            if todayTitles.isEmpty {
                content.body = "今日暂无待办事项 🎉"
            } else {
                let shown = todayTitles.prefix(3).joined(separator: "、")
                content.body = todayTitles.count > 3
                    ? "今天:\(shown) 等 \(todayTitles.count) 件"
                    : "今天:\(shown)(共 \(todayTitles.count) 件)"
            }
            content.sound = .default

            let weekly = AppSettings.digestRepeatType == "weekly"
            for (ti, hhmm) in AppSettings.digestTimes.enumerated() {
                let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                if weekly {
                    for day in AppSettings.digestDays {
                        var comps = DateComponents()
                        // 项目约定 0=周一…6=周日 → Calendar 的 1=周日…7=周六
                        comps.weekday = day == 6 ? 1 : day + 2
                        comps.hour = parts[0]
                        comps.minute = parts[1]
                        center.add(UNNotificationRequest(
                            identifier: "\(Self.digestID)-t\(ti)-d\(day)",
                            content: content,
                            trigger: UNCalendarNotificationTrigger(dateMatching: comps,
                                                                   repeats: true)))
                    }
                } else {
                    var comps = DateComponents()
                    comps.hour = parts[0]
                    comps.minute = parts[1]
                    center.add(UNNotificationRequest(
                        identifier: "\(Self.digestID)-t\(ti)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: comps,
                                                               repeats: true)))
                }
            }
        }
    }

    // MARK: - 响应处理(通知按钮与 app 内按钮共用)

    /// 完成/开始了:advance;重复事项完成一次会记入历史并排下一次。
    @MainActor
    func complete(_ task: TaskItem, context: ModelContext) {
        var d = task.data
        let finished = Scheduler.advance(&d, now: Date())
        task.apply(d)
        if finished {
            // 完成一次(含重复事项)即作为时长记忆样本
            DurationMemory.learn(title: d.title, durationMinutes: d.durationMinutes)
        }
        if finished && d.status == .pending {
            // 重复事项完成一次:插入一条已完成历史
            context.insert(TaskItem(title: d.title, remindAt: Date(),
                                    status: .done, doneAt: Date()))
        }
        try? context.save()
        if task.status == .done {
            cancelChain(for: task.uuid)
            WidgetBridge.sync(context: context)
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
                break  // 点通知本体:打开 app,不改状态
            }
        }
    }
}
