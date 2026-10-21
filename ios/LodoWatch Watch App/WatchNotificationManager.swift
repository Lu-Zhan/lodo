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
    /// 每次重排/撤销通知链 +1。对账拿到的是系统的异步快照,快照取得之后又重排过的话,
    /// 同一个标识可能已经换成了新一次发生的通知,按旧快照删会把新的删掉——版本变了就放弃这一轮。
    /// 只在主线程读写(rebuild/cancelChain/对账都在主线程)。
    private var chainVersion = 0

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
        #if DEBUG
        // 截图核对首页时别被授权弹窗挡住(simctl 点不了它)。
        if ProcessInfo.processInfo.arguments.contains("--demo-watch-today") { return }
        #endif
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 通知链

    /// 关掉「反复提醒」时到期只响一次(同手机):链缩成 1 条,也不追平——
    /// 原定时间已经过了就不再排。读的是手表本机的设置,由手机经 WatchConnectivity 推过来
    /// (`WatchSettingsSync`;还没收到过 = 开)。
    @MainActor
    func rebuild(for task: TaskItem, chainLength: Int = WatchNotificationManager.chainLength) {
        let center = UNUserNotificationCenter.current()
        cancelChain(for: task.uuid)
        // 「收集」里的事项(手机上建的,没有时间)不提醒。
        guard task.status == .pending, !task.isInbox else { return }

        let repeats = AppSettings.repeatReminderEnabled
        let interval = TimeInterval(AppSettings.snoozeMinutes * 60)
        let now = Date()
        var anchor = task.nextRemindAt
        if anchor <= now {
            guard repeats else { return }
            let missed = (now.timeIntervalSince(anchor) / interval).rounded(.down) + 1
            anchor = anchor.addingTimeInterval(missed * interval)
        }
        let length = repeats ? min(chainLength, Self.chainLength) : 1
        for i in 0..<length {
            let fire = anchor.addingTimeInterval(interval * Double(i))
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = Self.reminderBody(isEnd: task.phase == .end)
            content.sound = .default
            content.categoryIdentifier = Self.nagCategory
            // occurrence:这条通知属于哪一次发生。重复事项完成一次后 remindAt 顺延,
            // 通知中心里还留着的旧通知再点「完成」就对不上了,直接忽略(否则多记一笔完成历史)。
            content.userInfo = ["uuid": task.uuid.uuidString,
                                "occurrence": task.remindAt.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fire.timeIntervalSince(now), repeats: false)
            center.add(UNNotificationRequest(
                identifier: Self.identifier(task.uuid, index: i),
                content: content, trigger: trigger))
        }
    }

    private static func reminderBody(isEnd: Bool) -> String {
        if isEnd { return "时间到 — 完成了吗?" }
        return "到时间了"
    }

    private static let identifierPrefix = "watch-task-"

    private static func identifier(_ uuid: UUID, index: Int) -> String {
        "\(identifierPrefix)\(uuid.uuidString)-nag-\(index)"
    }

    /// 从通知标识里取回任务 uuid(`watch-task-<uuid>-nag-<i>`)。
    private static func taskUUID(fromIdentifier id: String) -> String? {
        guard id.hasPrefix(identifierPrefix), let range = id.range(of: "-nag-") else { return nil }
        return String(id[id.index(id.startIndex, offsetBy: identifierPrefix.count)..<range.lowerBound])
    }

    func cancelChain(for uuid: UUID) {
        chainVersion += 1
        let ids = (0..<Self.chainLength).map { Self.identifier(uuid, index: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 连通知中心里已经送达的那几条一起撤掉(完成之后不该还能点)。
    private func removeDelivered(for uuid: UUID) {
        let ids = (0..<Self.chainLength).map { Self.identifier(uuid, index: $0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// 重排全部待办的通知链(启动、回前台、任务数据变了——含 CloudKit 从手机同步过来的改动);
    /// 按全局预算分配,避免 8 条 × N 任务撞系统上限导致后续提醒静默丢失。
    /// 已经不在待办里的(在手机上完成/删除了)查不到,所以另外按系统里排着/送达的通知对账,
    /// 不属于任何有效待办的一律撤掉。
    @MainActor
    func refreshAll() {
        guard let context = container?.mainContext else { return }
        var pending = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        pending.sortBy = [SortDescriptor(\.nextRemindAt)]
        // 读库失败不能当成"没有待办",否则后面的对账会把所有通知都撤掉。
        guard let fetched = try? context.fetch(pending) else { return }
        // 收集里的事项不提醒;在手机上刚改成收集的,手表上还挂着原来那串通知,先撤掉。
        for task in fetched where task.isInbox { cancelChain(for: task.uuid) }
        let tasks = fetched.filter { !$0.isInbox }
        var budget = Self.chainBudget - tasks.count
        for task in tasks {
            let extra = max(0, min(Self.chainLength - 1, budget))
            budget -= extra
            rebuild(for: task, chainLength: 1 + extra)
        }
        removeOrphans()
    }

    /// 当前该响的待办:uuid → 这一次发生的 remindAt。在系统回调回到主线程之后才算——
    /// 不用发起对账那一刻的快照,不然等回调的这段时间里刚重排的通知会被旧快照误删。
    @MainActor
    private func currentOccurrences() -> [String: TimeInterval]? {
        guard let context = container?.mainContext,
              let tasks = try? context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == "pending" })) else { return nil }
        var map: [String: TimeInterval] = [:]
        for task in tasks where !task.isInbox {
            map[task.uuid.uuidString] = task.remindAt.timeIntervalSince1970
        }
        return map
    }

    /// 不属于任何该响的待办,或者属于它已经过去的那一次发生(重复事项在手机上完成过一次),
    /// 都算孤儿。没带 occurrence 的老通知只按 uuid 判。
    private static func isOrphan(_ request: UNNotificationRequest, current: [String: TimeInterval]) -> Bool {
        guard let uuid = taskUUID(fromIdentifier: request.identifier) else { return false }
        guard let occurrence = current[uuid] else { return true }
        if let stamped = request.content.userInfo["occurrence"] as? TimeInterval {
            return abs(stamped - occurrence) > 1
        }
        return false
    }

    @MainActor
    private func removeOrphans() {
        let center = UNUserNotificationCenter.current()
        let version = chainVersion
        center.getPendingNotificationRequests { requests in
            Task { @MainActor in
                guard version == self.chainVersion, let current = self.currentOccurrences() else { return }
                let ids = requests.filter { Self.isOrphan($0, current: current) }.map(\.identifier)
                if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
            }
        }
        center.getDeliveredNotifications { notifications in
            Task { @MainActor in
                guard version == self.chainVersion, let current = self.currentOccurrences() else { return }
                let ids = notifications.map(\.request).filter { Self.isOrphan($0, current: current) }
                    .map(\.identifier)
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }
    }

    // MARK: - 响应处理(通知按钮与 app 内按钮共用)

    @MainActor
    func complete(_ task: TaskItem, context: ModelContext) {
        var d = task.data
        let finished = Scheduler.advance(&d, now: Date())
        task.apply(d)
        if finished && d.status == .pending {
            let history = TaskItem(title: d.title, remindAt: Date(), status: .done, doneAt: Date())
            // 用药提醒:手表库里没有服药记录表,带上 medicationUUID,手机同步到之后
            // 按这条历史补记一笔服药(`MedicationStore.backfillDosesFromHistory`)。
            history.medicationUUID = task.medicationUUID
            context.insert(history)
        }
        try? context.save()
        removeDelivered(for: task.uuid)
        if task.status == .done {
            cancelChain(for: task.uuid)
        } else {
            rebuild(for: task)
        }
    }

    @MainActor
    func snooze(_ task: TaskItem, context: ModelContext) {
        // 「收集」里的事项没有提醒可以稍等:稍等会把 nextRemindAt 写成 15 分钟后,
        // 同步回手机就成了一条马上到期的任务。
        guard !task.isInbox else { return }
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
            // 旧一次发生的通知(重复事项已经完成过这一次、顺延到下一次了)不再生效。
            if let occurrence = userInfo["occurrence"] as? TimeInterval,
               abs(task.remindAt.timeIntervalSince1970 - occurrence) > 1 { return }
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
