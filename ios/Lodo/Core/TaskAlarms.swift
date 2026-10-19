import Foundation
import SwiftData
import LodoCore
#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI
#endif

/// 「用闹钟提醒」:开了闹钟的任务到原定时间由系统闹钟(AlarmKit,iOS 26+)响一次——
/// 静音、专注模式下也会响,锁屏整屏显示,上面有「完成」按钮。之后的纠缠照常交给通知链。
///
/// 和日历双向同步一样**整本对账,不逐处挂钩子**:`WidgetBridge.sync` 是每次任务数据变了
/// 都会走的扇出点,在那里调 `sync`,同一轮里的多次调用合并成一次。哪些该排、哪些该撤的判断
/// 在纯逻辑 `TaskAlarmPlan`。macOS 和 iOS 26 以前没有 AlarmKit,整套是空操作、表单里也不给开关。
@MainActor
enum TaskAlarms {
    /// 排闹钟时用的标题,按闹钟 id(= 任务 uuid)记。系统不回传闹钟上写的字,
    /// 改了任务标题时靠它判断要不要重排。
    private static let titlesKey = "taskAlarmTitles"
    private static var scheduled = false

    static var isSupported: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 用户在系统设置里拒绝了闹钟权限。
    static var isDenied: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return AlarmManager.shared.authorizationState == .denied
        }
        #endif
        return false
    }

    /// 打开开关时请求一次权限;返回是否可用。
    @discardableResult
    static func requestAuthorization() async -> Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            let manager = AlarmManager.shared
            switch manager.authorizationState {
            case .authorized: return true
            case .denied: return false
            default:
                return (try? await manager.requestAuthorization()) == .authorized
            }
        }
        #endif
        return false
    }

    /// 合并同一轮里的多次调用。
    static func sync(context: ModelContext) {
        guard isSupported, !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            scheduled = false
            await reconcile(context: context)
        }
    }

    static func reconcile(context: ModelContext) async {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        let manager = AlarmManager.shared
        let candidatesDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.alarm == true })
        let tasks = (try? context.fetch(candidatesDescriptor)) ?? []
        let existing = ((try? manager.alarms) ?? []).map { alarm in
            var fire: Date?
            if case .fixed(let date) = alarm.schedule { fire = date }
            return TaskAlarmPlan.Existing(id: alarm.id, fireDate: fire, alerting: alarm.state == .alerting)
        }
        // 没开过闹钟、系统里也没有我们的闹钟:什么都不用做,也别去碰授权状态。
        if tasks.isEmpty && existing.isEmpty { return }
        guard manager.authorizationState == .authorized else { return }

        let candidates = tasks.map {
            TaskAlarmPlan.Candidate(id: $0.uuid, title: $0.title, remindAt: $0.remindAt,
                                    pending: $0.status == .pending, alarm: $0.alarm)
        }
        let desired = TaskAlarmPlan.desired(
            candidates, now: Date(),
            quietStart: AppSettings.quietHoursStart, quietEnd: AppSettings.quietHoursEnd,
            quietEnabled: AppSettings.quietHoursEnabled)
        var titles = storedTitles()
        let pendingIDs = Set(tasks.filter { $0.status == .pending }.map(\.uuid))
        let changes = TaskAlarmPlan.changes(desired: desired, existing: existing,
                                            titles: titles, pendingIDs: pendingIDs)
        for id in changes.cancel {
            try? manager.cancel(id: id)
            titles[id] = nil
        }
        for alarm in changes.schedule {
            do {
                _ = try await manager.schedule(id: alarm.id,
                                               configuration: configuration(for: alarm))
                titles[alarm.id] = alarm.title
            } catch {
                titles[alarm.id] = nil
            }
        }
        // 只留系统里还在的那些(响完自己消失的闹钟,标题记录一起清掉)。
        let alive = Set(((try? manager.alarms) ?? []).map(\.id))
        titles = titles.filter { alive.contains($0.key) }
        saveTitles(titles)
        #endif
    }

    // MARK: - 标题记录

    private static func storedTitles() -> [UUID: String] {
        guard let data = UserDefaults.standard.data(forKey: titlesKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [UUID: String] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    private static func saveTitles(_ titles: [UUID: String]) {
        let raw = Dictionary(uniqueKeysWithValues: titles.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: titlesKey)
    }

    // MARK: - 闹钟外观

    #if os(iOS)
    @available(iOS 26.0, *)
    private static func configuration(
        for alarm: TaskAlarmPlan.Desired
    ) -> AlarmManager.AlarmConfiguration<TaskAlarmMetadata> {
        // 闹钟界面由系统在 app 外面画,按系统语言解析 LocalizedStringResource;
        // 这里先按应用内语言取好字,再原样交过去(查不到表就显示原文)。
        let doneText = String(localized: "完成", bundle: .appLanguage(),
                              locale: AppSettings.language.locale)
        let closeText = String(localized: "关闭", bundle: .appLanguage(),
                               locale: AppSettings.language.locale)
        let done = AlarmButton(text: LocalizedStringResource(stringLiteral: doneText),
                               textColor: .white, systemImageName: "checkmark")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: alarm.title),
                secondaryButton: done, secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: alarm.title),
                stopButton: AlarmButton(text: LocalizedStringResource(stringLiteral: closeText),
                                        textColor: .white, systemImageName: "xmark"),
                secondaryButton: done, secondaryButtonBehavior: .custom)
        }
        let palette = AccentPalette(rawValue: UserDefaults.standard.string(
            forKey: AppSettings.accentPaletteKey) ?? "") ?? .terracotta
        let attributes = AlarmAttributes<TaskAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert), tintColor: palette.fill)
        return .alarm(schedule: .fixed(alarm.fireDate), attributes: attributes,
                      secondaryIntent: CompleteAlarmTaskIntent(taskID: alarm.id.uuidString))
    }
    #endif
}

#if os(iOS)
@available(iOS 26.0, *)
struct TaskAlarmMetadata: AlarmMetadata {}

/// 闹钟上的「完成」:把那条任务标成完成(和通知上的「完成」同一条路)。
struct CompleteAlarmTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "完成闹钟提醒的任务"
    static let isDiscoverable = false

    @Parameter(title: "任务")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LodoIntentSupport.ensureConfigured()
        guard let uuid = UUID(uuidString: taskID) else { return .result() }
        let context = LodoIntentSupport.context
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        if let task = try? context.fetch(descriptor).first, task.status == .pending {
            NotificationManager.shared.complete(task, context: context)
        }
        return .result()
    }
}
#endif
