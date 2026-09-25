import Foundation
import SwiftData
import LodoCore
#if os(iOS)
import EventKit
#endif

/// 系统日历的读写桥接。纯逻辑(周计算、事件归日、任务→事件的取值规则)在
/// `LodoCore/CalendarPlan.swift`,这里只负责和 EventKit 打交道。
///
/// 三条约定,和 `HealthKitBridge` 一脉相承:
/// 1. **两个开关、默认都关**——`AppSettings.calendarEnabled` 管读,
///    `calendarWriteEnabled` 管写且是前者的下级。关着时一次 EventKit 调用都不发。
/// 2. **静默降级**——没授权/查不到/存不进一律当"没有日历数据",不抛错打断任务页。
/// 3. **写只写自己那本**——lodo 任务镜像进一本自己建的日历(名字就叫 lodo),
///    读事件时把这本排除掉,否则自己写进去的任务会当成"系统事件"再读回来显示两遍;
///    删除时也只动这本里带 lodo URL 的事件,绝不碰用户自己的日程。
///
/// macOS 上不做(EventKit 在 macOS 要另配沙盒 entitlement,而 macOS 端本来就是
/// 捎带支持),整份实现 `#if os(iOS)` 门控、另一侧留同名空实现,调用方不写平台判断。
@MainActor
enum CalendarBridge {

#if os(iOS)
    private static let store = EKEventStore()
    /// lodo 自己那本日历的名字。用户在系统日历 app 里能看到它、能单独隐藏。
    static let ownCalendarTitle = "lodo"

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 请求完整访问(要写事件,writeOnly 不够——回读自己写过的事件也需要读权限)。
    @discardableResult
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    // MARK: - 读

    /// 某一段时间里的系统事件(不含 lodo 自己那本日历)。
    /// 开关关着、没授权、查询出错都返回空数组——调用方按"今天没有事件"渲染即可。
    static func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard AppSettings.calendarEnabled, isAuthorized, start < end else { return [] }
        let calendars = store.calendars(for: .event).filter { $0.title != ownCalendarTitle }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "(无标题)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar?.title ?? "")
        }
    }

    // MARK: - 写

    /// 把当前未完成的任务镜像进 lodo 那本日历:有则更新、无则新建、任务没了就删掉。
    ///
    /// **只在一个窗口内对账**(往前 7 天、往后 90 天):日历里没有"全部事件"这种
    /// 查询,必须给区间;窗口外的旧事件留着不动,反正用户也翻不到那么远的将来。
    static func syncTasks(_ mirrors: [CalendarTaskMirror]) {
        guard AppSettings.calendarWriteEnabled, isAuthorized,
              let calendar = ensureOwnCalendar() else { return }
        let now = Date()
        let windowStart = now.addingTimeInterval(-7 * 86400)
        let windowEnd = now.addingTimeInterval(90 * 86400)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd,
                                                 calendars: [calendar])
        var existing: [UUID: EKEvent] = [:]
        for event in store.events(matching: predicate) {
            guard let uuid = CalendarTaskMirror.taskUUID(fromEventURL: event.url) else { continue }
            // 同一件任务在窗口里理应只有一条;万一重复(手动拷贝过),留一条删其余。
            if existing[uuid] != nil {
                try? store.remove(event, span: .thisEvent, commit: false)
            } else {
                existing[uuid] = event
            }
        }

        let wanted = mirrors.filter { $0.start >= windowStart && $0.start <= windowEnd }
        var keep: Set<UUID> = []
        for mirror in wanted {
            keep.insert(mirror.uuid)
            let event = existing[mirror.uuid] ?? EKEvent(eventStore: store)
            // 没变就不写:每次 save 都会让系统日历产生一次变更通知,没必要。
            if existing[mirror.uuid] != nil, event.title == mirror.title,
               event.startDate == mirror.start, event.endDate == mirror.end,
               event.isAllDay == mirror.isAllDay {
                continue
            }
            event.calendar = calendar
            event.title = mirror.title
            event.startDate = mirror.start
            event.endDate = mirror.end
            event.isAllDay = mirror.isAllDay
            event.url = mirror.eventURL
            try? store.save(event, span: .thisEvent, commit: false)
        }
        for (uuid, event) in existing where !keep.contains(uuid) {
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    /// 关掉写开关时把 lodo 写过的事件清干净(窗口同上)。用户关开关的意思就是
    /// "别在我日历里留东西",留一堆孤儿事件比不同步更糟。
    static func removeAllMirroredEvents() {
        guard isAuthorized, let calendar = ownCalendar() else { return }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-365 * 86400),
            end: now.addingTimeInterval(365 * 86400), calendars: [calendar])
        for event in store.events(matching: predicate)
        where CalendarTaskMirror.taskUUID(fromEventURL: event.url) != nil {
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }

    // MARK: - lodo 自己那本日历

    private static func ownCalendar() -> EKCalendar? {
        if let identifier = AppSettings.calendarIdentifier,
           let found = store.calendar(withIdentifier: identifier) {
            return found
        }
        return store.calendars(for: .event).first { $0.title == ownCalendarTitle }
    }

    /// 找不到就新建一本。挂在默认日历的 source 下(iCloud 账户则跟着同步到其他
    /// 设备);连默认日历都没有时退回本地 source,再没有就放弃(返回 nil,
    /// 上面按"写不了"静默跳过)。
    private static func ensureOwnCalendar() -> EKCalendar? {
        if let existing = ownCalendar() {
            AppSettings.setCalendarIdentifier(existing.calendarIdentifier)
            return existing
        }
        guard let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first else { return nil }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = ownCalendarTitle
        calendar.source = source
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return nil }
        AppSettings.setCalendarIdentifier(calendar.calendarIdentifier)
        return calendar
    }
#else
    // macOS:EventKit 这条路不做,留同名空实现,调用方不写平台判断。
    static let ownCalendarTitle = "lodo"
    static var isAuthorized: Bool { false }
    @discardableResult
    static func requestAccess() async -> Bool { false }
    static func events(from start: Date, to end: Date) -> [CalendarEvent] { [] }
    static func syncTasks(_ mirrors: [CalendarTaskMirror]) {}
    static func removeAllMirroredEvents() {}
#endif
}

/// 数据变更后把任务镜像进系统日历的统一入口。和 `WidgetBridge.sync(context:)`
/// 一样挂在"事项有变动"的地方,自己判断开关、自己做窗口对账。
@MainActor
enum CalendarSync {
    /// 合并同一轮里的多次请求:AI 批量执行会连着改十几条事项,每条都整本对账
    /// 一遍纯属浪费。置位后丢到下一个 runloop 再跑,中间再来的调用直接忽略。
    private static var scheduled = false

    /// 把库里全部未完成事项同步一遍。**整本对账而不是逐条增量**:完成、删除、
    /// 改期、撤销这些路径太多,逐个挂钩子迟早漏一条,而一次对账本来就要把窗口内
    /// 的事件全查出来,顺带比一遍几乎不多花什么。
    static func sync(context: ModelContext) {
        guard AppSettings.calendarWriteEnabled, !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            scheduled = false
            reconcile(context: context)
        }
    }

    /// 立即对账(不合并)。开关刚打开、回前台这类"就这一次"的场景用它。
    static func reconcile(context: ModelContext) {
        guard AppSettings.calendarWriteEnabled else { return }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        let tasks = (try? context.fetch(descriptor)) ?? []
        let mirrors = tasks.compactMap { CalendarTaskMirror.from($0.data, uuid: $0.uuid) }
        CalendarBridge.syncTasks(mirrors)
    }
}
