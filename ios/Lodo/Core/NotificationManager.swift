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
    static let rescheduleAction = "LODO_RESCHEDULE"
    static let digestID = "lodo-digest"
    private static let chainLength = 8

    /// 通知"改期"按钮交接给 app 前台的 uuid(双通道:UserDefaults 兜底冷启动/
    /// 回前台消费,NotificationCenter 广播供已在前台时的快路径),
    /// 与 LodoIntents.swift 里 Siri 的 agent handoff 是同一种模式。
    static let pendingRescheduleUUIDKey = "pendingRescheduleUUID"
    static let rescheduleHandoff = Notification.Name("LodoRescheduleHandoff")

    private var container: ModelContainer?

    func configure(container: ModelContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.doneAction, title: "完成",
                                        options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "稍等一会",
                                          options: [])
        // 改期要打开 App 展示改期候选,不像完成/稍等能在后台静默处理,所以带 .foreground。
        let reschedule = UNNotificationAction(identifier: Self.rescheduleAction, title: "改期",
                                              options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.nagCategory, actions: [done, snooze, reschedule],
                                   intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 通知链

    /// 系统 pending 通知上限 64,给纠缠链留的全局预算(汇总等另计)。
    private static let chainBudget = 48

    /// 取消并重排某事项的通知链,并同步小组件快照。
    /// chainLength:本次预排的链长(refreshAll 按预算分配;单任务变更用满 8 条)。
    @MainActor
    func rebuild(for task: TaskItem, chainLength: Int = NotificationManager.chainLength,
                 syncWidget: Bool = true) {
        if syncWidget, let context = container?.mainContext {
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
        for i in 0..<min(chainLength, Self.chainLength) {
            let fire = anchor.addingTimeInterval(interval * Double(i))
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = Self.reminderBody(style: AppSettings.agentPersonaStyle, starting: starting,
                                             isEnd: task.phase == .end,
                                             durationMinutes: task.durationMinutes)
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

    /// 4 个预设说话风格各一套提醒文案模板(到点/该开始/时间到三阶段);
    /// "默认"和"自定义"(自由文本、无法预先枚举模板)沿用原文案。
    /// 通知链是预排的、不会实时调用 AI,所以这里是本地写死的文案,不引入网络依赖。
    private static let reminderTemplates: [String: (due: String, start: String, end: String)] = [
        "高效秘书": ("到时间了,请处理。", "该开始了,请预留 %d 分钟。", "时间已到,请确认完成情况。"),
        "温柔陪伴": ("到时间啦,别忘了哦~", "要开始啦~大概需要 %d 分钟,加油!", "时间到啦,完成了吗?"),
        "严格教练": ("时间到了,马上行动!", "该开始了!给自己 %d 分钟,专注去做。", "时间到,完成了没有?"),
        "幽默轻松": ("叮!你的专属提醒到啦~", "开工时间到~预计 %d 分钟,冲鸭!", "时间到啦,搞定了没?别偷懒哦~"),
    ]

    private static func reminderBody(style: String, starting: Bool, isEnd: Bool,
                                     durationMinutes: Int) -> String {
        guard let template = reminderTemplates[style] else {
            if starting { return "该开始了!(时长 \(durationMinutes) 分钟)" }
            if isEnd { return "时间到 — 完成了吗?" }
            return "到时间了"
        }
        if starting { return String(format: template.start, durationMinutes) }
        if isEnd { return template.end }
        return template.due
    }

    func cancelChain(for uuid: UUID) {
        let ids = (0..<Self.chainLength).map { "task-\(uuid.uuidString)-nag-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 重排全部待办的通知链和每日汇总(app 启动/回到前台时调用)。
    /// 通知链按全局预算分配:每任务先保底 1 条,剩余额度按到期先后补满,
    /// 避免 8 条 × N 任务撞系统 64 条上限导致后续提醒静默丢失。
    @MainActor
    func refreshAll() {
        guard let context = container?.mainContext else { return }
        var pending = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        pending.sortBy = [SortDescriptor(\.nextRemindAt)]
        let tasks = (try? context.fetch(pending)) ?? []
        var budget = Self.chainBudget - tasks.count  // 每任务保底 1 条之外的余量
        for task in tasks {
            let extra = max(0, min(Self.chainLength - 1, budget))
            budget -= extra
            rebuild(for: task, chainLength: 1 + extra, syncWidget: false)
        }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        let todayTasks = tasks
            .filter { $0.nextRemindAt < endOfToday }
            .sorted { $0.nextRemindAt < $1.nextRemindAt }
        refreshDigest(for: todayTasks)
        WidgetBridge.sync(context: context)
    }

    // MARK: - 汇总正文的 AI 改写

    private static let digestSummaryInputKey = "digestSummaryInput"
    private static let digestSummaryTextKey = "digestSummaryText"

    /// 排汇总通知:优先用 AI 一句话概括(同一天同一批事项只调用一次,缓存),
    /// 无 key/未返回前先用机械文案兜底,AI 成功后重排。
    private func refreshDigest(for todayTasks: [TaskItem]) {
        let titles = todayTasks.map(\.title)
        // 事项带时间与时长,供模型判断重点
        let items = todayTasks.map { task in
            var line = "\(task.title)(\(TaskItem.format(task.nextRemindAt))"
            if task.durationMinutes > 0 { line += ",\(task.durationMinutes) 分钟" }
            return line + ")"
        }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let input = "\(day)|" + items.joined(separator: ";")
        let defaults = UserDefaults.standard

        if !titles.isEmpty,
           defaults.string(forKey: Self.digestSummaryInputKey) == input,
           let cached = defaults.string(forKey: Self.digestSummaryTextKey) {
            updateDigest(todayTitles: titles, aiSummary: cached)
            return
        }
        updateDigest(todayTitles: titles)
        guard AppSettings.digestEnabled, !titles.isEmpty,
              DeepSeekClient.isConfigured else { return }
        Task {
            guard let summary = try? await DeepSeekClient.summarizeToday(items) else { return }
            defaults.set(input, forKey: Self.digestSummaryInputKey)
            defaults.set(summary, forKey: Self.digestSummaryTextKey)
            self.updateDigest(todayTitles: titles, aiSummary: summary)
        }
    }

    /// 待办汇总:按设置的时间点与重复方式(每天/每周选中周几)排系统重复通知,
    /// 内容为今天开始或到期的事项(含已过期;app 进前台时刷新快照);
    /// aiSummary 非空时用 AI 的一句话概括作为正文。
    func updateDigest(todayTitles: [String], aiSummary: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            // 时间点/周几数量会变,按前缀清掉旧的(含老版本的单条 id)
            let old = requests.map(\.identifier).filter { $0.hasPrefix(Self.digestID) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard AppSettings.digestEnabled else { return }

            let content = UNMutableNotificationContent()
            content.title = "每日待办汇总"
            if let aiSummary, !todayTitles.isEmpty {
                content.body = aiSummary
            } else if todayTitles.isEmpty {
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
            case Self.rescheduleAction:
                UserDefaults.standard.set(uuidString, forKey: Self.pendingRescheduleUUIDKey)
                NotificationCenter.default.post(name: Self.rescheduleHandoff, object: nil,
                                                userInfo: ["uuid": uuidString])
            default:
                break  // 点通知本体:打开 app,不改状态
            }
        }
    }
}
