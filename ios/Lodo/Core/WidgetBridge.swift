import Foundation
import SwiftData
import WidgetKit
import LodoCore

/// App Group 共享容器:数据库与小组件快照都放这里,app 和小组件两侧共用。
enum AppGroup {
    static let id = "group.com.lodo.app"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var storeURL: URL? { containerURL?.appending(path: "lodo.store") }
    static var snapshotURL: URL? { containerURL?.appending(path: "widget-upcoming.json") }
    /// 锁屏小组件(今日 / 重要的事 / 倒数日)的快照,见 `WidgetBridge.LockScreenSnapshot`。
    static var lockScreenSnapshotURL: URL? { containerURL?.appending(path: "widget-lockscreen.json") }

    /// AI 收藏的原始文件目录(按需创建);Inbox 是 Share Extension 的收件箱,
    /// 扩展只往里落文件,主 app 回前台时消费。
    static var memoryDirURL: URL? { directory("Memory") }
    static var inboxDirURL: URL? { directory("Memory/Inbox") }
    /// 人脉头像与附件目录,与 Memory/ 同级独立存放。
    static var contactsDirURL: URL? { directory("Contacts") }

    private static func directory(_ path: String) -> URL? {
        guard let url = containerURL?.appending(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 老版本数据库在默认位置(Application Support/default.store),
    /// 迁到 App Group 前先整套拷过去,避免升级丢数据。
    static func migrateLegacyStoreIfNeeded(to newURL: URL) {
        let fm = FileManager.default
        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard !fm.fileExists(atPath: newURL.path),
              fm.fileExists(atPath: legacy.path) else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? fm.copyItem(at: URL(fileURLWithPath: legacy.path + suffix),
                             to: URL(fileURLWithPath: newURL.path + suffix))
        }
    }
}

/// 把即将到来的待办快照写进 App Group,并让小组件刷新。
/// 字段与 LodoWidget 的 UpcomingItem 保持一致。
enum WidgetBridge {
    private struct Item: Codable {
        let title: String
        let at: Date
    }

    /// 上次写入的快照,内容未变时不写盘、不 reload(去抖)。
    @MainActor
    private static var lastSnapshot: Data?
    @MainActor
    private static var lastLockScreenSnapshot: Data?

    /// 锁屏小组件的快照。字段与 LodoWidget 的 `LockScreenSnapshot` 保持一致
    /// (小组件 target 不链接 LodoCore,和 UpcomingItem 同样的重复策略)。
    ///
    /// **文案由 app 这边按应用内语言算好再写进去**:小组件进程读不到应用内语言
    /// 设置,倒数日"还有 12 天"这种句子也要用到 LodoCore 的计算——所以倒数日按
    /// 接下来 8 天每天 0 点各算一份,小组件按时间线取当天那份,不用自己算。
    struct LockScreenSnapshot: Codable, Equatable {
        struct Line: Codable, Equatable {
            let title: String
            /// 任务的提醒时刻 / 日程的开始时刻;全天的日程是那天 0 点。
            let at: Date?
            /// 日程的结束时刻(小组件据此在它结束后把它拿掉);任务为 nil。
            let end: Date?
            let allDay: Bool
            let isEvent: Bool
        }
        struct CountdownLine: Codable, Equatable {
            let title: String
            let text: String
        }
        struct CountdownDay: Codable, Equatable {
            /// 从这一刻起用这一份(当天 0 点)。
            let from: Date
            let lines: [CountdownLine]
        }
        struct Labels: Codable, Equatable {
            let today: String
            let pinned: String
            let countdown: String
            let allDay: String
            let emptyToday: String
            let emptyPinned: String
            let emptyCountdown: String
            let agent: String
        }
        let today: [Line]
        let pinned: [Line]
        let countdown: [CountdownDay]
        let labels: Labels
    }

    @MainActor
    static func sync(context: ModelContext) {
        guard let url = AppGroup.snapshotURL else { return }
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" },
            sortBy: [SortDescriptor(\.nextRemindAt)])
        // 宽口径拉取,和 LodoIntentSupport.pendingTasks() 一致;真正"今天或更早"
        // 的过滤在下面用 Swift 做(与 LodoIntentSupport.todayPending() 同一语义),
        // 这里不能直接复用那个函数——它在 #if os(iOS) 的 Intents 文件里,而这个
        // 文件要为 macOS 主 app 一起编译。
        descriptor.fetchLimit = 50
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        let items = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.nextRemindAt < endOfToday }
            .prefix(8)
            .map { Item(title: $0.title, at: $0.nextRemindAt) }
        let lockScreenChanged = syncLockScreen(context: context, endOfToday: endOfToday)
        guard let data = try? JSONEncoder().encode(items) else { return }
        if data == lastSnapshot {
            if lockScreenChanged { WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        lastSnapshot = data
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 写锁屏快照;内容和上次一样时不写盘,返回是否有变化。
    @MainActor
    private static func syncLockScreen(context: ModelContext, endOfToday: Date) -> Bool {
        guard let url = AppGroup.lockScreenSnapshotURL else { return false }
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let locale = AppSettings.language.locale

        // 今日:今天(含逾期)还没完成的任务 + 今天还没结束的系统日程,按时间排。
        let pendingDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" },
            sortBy: [SortDescriptor(\.nextRemindAt)])
        let pending = (try? context.fetch(pendingDescriptor)) ?? []
        let taskLines = pending.filter { $0.nextRemindAt < endOfToday }.map {
            LockScreenSnapshot.Line(title: $0.title, at: $0.nextRemindAt, end: nil,
                                    allDay: $0.allDay, isEvent: false)
        }
        let eventLines = CalendarBridge.events(from: startOfDay, to: endOfToday)
            .filter { $0.isAllDay || $0.end > now }
            .map {
                LockScreenSnapshot.Line(title: $0.title, at: $0.isAllDay ? startOfDay : $0.start,
                                        end: $0.end, allDay: $0.isAllDay, isEvent: true)
            }
        let today = (taskLines + eventLines)
            .sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
            .prefix(8)

        // 重要的事:置顶的未完成任务,最近置顶的在前。
        let pinned = pending.filter(\.pinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
            .prefix(5)
            .map { LockScreenSnapshot.Line(title: $0.title, at: $0.nextRemindAt, end: nil,
                                           allDay: $0.allDay, isEvent: false) }

        // 倒数日:接下来 8 天每天 0 点各算一份(今天那份按现在算)。
        let entries = ((try? context.fetch(FetchDescriptor<CountdownEvent>())) ?? []).map(\.entry)
        let countdown: [LockScreenSnapshot.CountdownDay] = (0..<8).compactMap { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: startOfDay) else {
                return nil
            }
            let moment = offset == 0 ? now : dayStart
            let lines = CountdownPlan.widgetEntries(entries, now: moment).map { entry in
                LockScreenSnapshot.CountdownLine(
                    title: entry.title,
                    text: CountdownText.text(CountdownPlan.primary(entry, now: moment),
                                             hasEnd: entry.end != nil, precise: false))
            }
            // from 一律取当天 0 点:用 now 的话每次同步快照都不一样,会一直写盘、刷新小组件。
            return LockScreenSnapshot.CountdownDay(from: dayStart, lines: lines)
        }

        let labels = LockScreenSnapshot.Labels(
            today: String(localized: "今日", bundle: .appLanguage(), locale: locale),
            pinned: String(localized: "重要的事", bundle: .appLanguage(), locale: locale),
            countdown: String(localized: "倒数日", bundle: .appLanguage(), locale: locale),
            allDay: String(localized: "全天", bundle: .appLanguage(), locale: locale),
            emptyToday: String(localized: "今天没有安排", bundle: .appLanguage(), locale: locale),
            emptyPinned: String(localized: "长按任务即可置顶", bundle: .appLanguage(), locale: locale),
            emptyCountdown: String(localized: "在倒数日里选要显示的", bundle: .appLanguage(), locale: locale),
            agent: String(localized: "AI 助手", bundle: .appLanguage(), locale: locale))
        let snapshot = LockScreenSnapshot(today: Array(today), pinned: Array(pinned),
                                          countdown: countdown, labels: labels)
        guard let data = try? JSONEncoder().encode(snapshot), data != lastLockScreenSnapshot else {
            return false
        }
        lastLockScreenSnapshot = data
        try? data.write(to: url, options: .atomic)
        return true
    }
}
