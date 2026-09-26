import Foundation
import SwiftData
import LodoCore
#if os(iOS)
import EventKit
#endif

/// 系统日历的读写桥接。纯逻辑(周计算、事件归日、任务→事件的取值规则)在
/// `LodoCore/CalendarPlan.swift`,这里只负责和 EventKit 打交道。
///
/// 几条约定,和 `HealthKitBridge` 一脉相承:
/// 1. **两个开关、默认都关**——`AppSettings.calendarEnabled` 管读,
///    `calendarWriteEnabled` 管写且是前者的下级。关着时一次 EventKit 调用都不发。
/// 2. **静默降级**——没授权/查不到/存不进一律当"没有日历数据",不抛错打断日历页。
/// 3. **写只写自己那本**——lodo 任务镜像进一本自己建的日历(名字就叫 lodo),
///    读事件时把这本排除掉,否则自己写进去的任务会当成"系统事件"再读回来显示两遍;
///    删除时也只动这本里带 lodo URL 的事件,绝不碰用户自己的日程。
/// 4. **用户自己的日程可以在日历页里改**——但不经这个文件写:点开一条事件时
///    `ekEvent(for:)` 取回那一次发生,交给系统的 `EKEventViewController`
///    (带编辑/删除,保存要用户自己点),lodo 不替用户改任何一个字段。
/// 5. **双向**——日历那边改了时间/标题会回写进任务,在日历里删掉事件会连任务一起
///    删掉(用户确认过的语义)。谁改了、冲突算谁的、什么时候算"被删",全部由
///    `CalendarSyncPlanner` 这个纯函数判断,这里只负责执行它算出来的 plan。
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

    /// 用户明确拒绝过(或被家长控制限制)。这时再请求也不会弹窗,日历页改为
    /// 引导去系统设置。
    static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted || status == .writeOnly
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
        return store.events(matching: predicate).map(snapshot)
    }

    /// 日历页点开一条事件时,取回**那一次发生**的 EKEvent 交给系统的详情/编辑界面。
    /// 不能直接 `event(withIdentifier:)`:重复事件的每一次发生共用同一个 id,
    /// 那样取回来的永远是第一次,改的也就是第一次。按开始时间所在的那一天查
    /// 一遍,再用 id + 开始时间认出是哪一次。
    static func ekEvent(for event: CalendarEvent) -> EKEvent? {
        guard AppSettings.calendarEnabled, isAuthorized else { return nil }
        let dayStart = Calendar.current.startOfDay(for: event.start)
        let predicate = store.predicateForEvents(
            withStart: dayStart.addingTimeInterval(-86400),
            end: dayStart.addingTimeInterval(2 * 86400), calendars: nil)
        return store.events(matching: predicate).first {
            $0.eventIdentifier == event.id && $0.startDate == event.start
        } ?? store.event(withIdentifier: event.id)
    }

    /// 系统详情/编辑界面要拿同一个 store(EKEventViewController 用它保存)。
    static var eventStore: EKEventStore { store }

    // MARK: - 写

    /// 对账窗口:往前 7 天、往后 90 天。日历里没有"全部事件"这种查询,必须给区间;
    /// **窗口外查不到不等于被删**,这个区分在 `CalendarSyncPlanner` 里要用到。
    static func syncWindow(now: Date = Date()) -> ClosedRange<Date> {
        now.addingTimeInterval(-7 * 86400)...now.addingTimeInterval(90 * 86400)
    }

    /// lodo 自己那本日历在窗口内的事件,连带"事件 id → 任务 uuid"(读事件 URL)。
    /// 账本丢了之后靠这张表把镜像关系认回来。
    static func ownEvents(in window: ClosedRange<Date>)
        -> (events: [CalendarEvent], claimed: [String: UUID]) {
        guard isAuthorized, let calendar = ownCalendar() else { return ([], [:]) }
        let predicate = store.predicateForEvents(withStart: window.lowerBound,
                                                 end: window.upperBound, calendars: [calendar])
        var events: [CalendarEvent] = []
        var claimed: [String: UUID] = [:]
        for event in store.events(matching: predicate) {
            guard let id = event.eventIdentifier else { continue }
            events.append(snapshot(event))
            if let uuid = CalendarTaskMirror.taskUUID(fromEventURL: event.url) {
                claimed[id] = uuid
            }
        }
        return (events, claimed)
    }

    /// 按 id 取几条事件(账本里认领过的、别人家日历里那些)。取不到的就是被删了。
    static func events(withIDs ids: [String]) -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        return ids.compactMap { store.event(withIdentifier: $0).map(snapshot) }
    }

    private static func snapshot(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title ?? "(无标题)", start: event.startDate,
                      end: event.endDate, isAllDay: event.isAllDay,
                      calendarTitle: event.calendar?.title ?? "",
                      calendarColor: color(of: event.calendar),
                      location: event.location)
    }

    private static func color(of calendar: EKCalendar?) -> CalendarEventColor? {
        guard let cgColor = calendar?.cgColor,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        return CalendarEventColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }

    /// 执行 plan 的**事件那一侧**(新建/更新/删除),返回新建出来的事件 id,
    /// 调用方据此把账本补全。任务那一侧由 `CalendarSync` 执行——那边要动
    /// SwiftData 和通知链,不该塞进这个只管 EventKit 的文件里。
    @discardableResult
    static func apply(_ plan: CalendarSyncPlan) -> [UUID: String] {
        guard isAuthorized, let calendar = ensureOwnCalendar() else { return [:] }
        var created: [UUID: String] = [:]

        for mirror in plan.createEvents {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            write(mirror, into: event)
            guard (try? store.save(event, span: .thisEvent, commit: false)) != nil else { continue }
            if let id = event.eventIdentifier { created[mirror.uuid] = id }
        }
        for (eventID, mirror) in plan.updateEvents {
            guard let event = store.event(withIdentifier: eventID) else { continue }
            write(mirror, into: event)
            try? store.save(event, span: .thisEvent, commit: false)
        }
        for eventID in plan.deleteEventIDs {
            guard let event = store.event(withIdentifier: eventID) else { continue }
            try? store.remove(event, span: .thisEvent, commit: false)
        }
        try? store.commit()
        return created
    }

    /// 写字段。**URL 只在自己那本日历里写**——别人家日历里的事件是用户的,
    /// 往上面盖一个 lodo:// 链接属于改人家的数据。
    private static func write(_ mirror: CalendarTaskMirror, into event: EKEvent) {
        event.title = mirror.title
        event.startDate = mirror.start
        event.endDate = mirror.end
        event.isAllDay = mirror.isAllDay
        if event.calendar?.title == ownCalendarTitle {
            event.url = mirror.eventURL
        }
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
    static var isDenied: Bool { false }
    @discardableResult
    static func requestAccess() async -> Bool { false }
    static func events(from start: Date, to end: Date) -> [CalendarEvent] { [] }
    static func syncWindow(now: Date = Date()) -> ClosedRange<Date> { now...now }
    static func ownEvents(in window: ClosedRange<Date>)
        -> (events: [CalendarEvent], claimed: [String: UUID]) { ([], [:]) }
    static func events(withIDs ids: [String]) -> [CalendarEvent] { [] }
    @discardableResult
    static func apply(_ plan: CalendarSyncPlan) -> [UUID: String] { [:] }
    static func removeAllMirroredEvents() {}
#endif
}

/// 双向对账的执行者:把 `CalendarSyncPlanner` 算出来的 plan 落到两边。
///
/// 和 `WidgetBridge.sync(context:)` 一样挂在"事项有变动"的地方,自己判断开关。
/// **双向整套受写开关门控**——只读展示不需要账本,也不该因为看了一眼日历
/// 就把任务改掉。
@MainActor
enum CalendarSync {
    /// 合并同一轮里的多次请求:AI 批量执行会连着改十几条事项,每条都对账一遍
    /// 纯属浪费。置位后丢到下一个 runloop 再跑,中间再来的调用直接忽略。
    private static var scheduled = false
    /// 正在落 plan 的任务侧改动。回写任务会触发 TaskActions → WidgetBridge.sync →
    /// 又调回这里,不挡住就会无限递归(而且第二次进来时账本还没存,会把刚回写的
    /// 改动当成"任务这边改了"再推回日历)。
    private static var applying = false

    static func sync(context: ModelContext) {
        guard AppSettings.calendarWriteEnabled, !applying, !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            scheduled = false
            reconcile(context: context)
        }
    }

    /// 立即对账(不合并)。开关刚打开、回前台、收到系统日历变更通知时用它。
    static func reconcile(context: ModelContext) {
        guard AppSettings.calendarWriteEnabled, CalendarBridge.isAuthorized, !applying else { return }
        let window = CalendarBridge.syncWindow()
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "pending" })
        let tasks = (try? context.fetch(descriptor)) ?? []
        let mirrors = tasks.compactMap { CalendarTaskMirror.from($0.data, uuid: $0.uuid) }
            .filter { window.contains($0.start) }
        let tasksByUUID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.uuid, $0) })

        let records = CalendarSyncLedger.records
        let own = CalendarBridge.ownEvents(in: window)
        // 别人家日历里被「转为任务」认领过的那几条,按 id 单独取(它们不在
        // 自家日历的查询结果里)。
        let foreignIDs = records.filter { !$0.isOwnCalendar }.map(\.eventID)
        let events = own.events + CalendarBridge.events(withIDs: foreignIDs)

        let plan = CalendarSyncPlanner.plan(records: records, tasks: mirrors, events: events,
                                            claimedUUIDs: own.claimed, window: window)
        guard !plan.isEmpty || plan.records != records else { return }

        applying = true
        defer { applying = false }

        // ① 事件侧
        let created = CalendarBridge.apply(plan)

        // ② 任务侧:回写改动
        for update in plan.updateTasks {
            guard let task = tasksByUUID[update.uuid] else { continue }
            // 走和表单保存同一条路(TaskActions.apply):它会重置 phase、把
            // nextRemindAt 拉回 remindAt 并重排通知链——少了这几步,改完时间
            // 提醒还挂在旧时刻上。
            TaskActions.apply(ParsedTask(
                title: update.title, remindAt: update.start, allDay: update.isAllDay,
                durationMinutes: update.durationMinutes, repeatType: task.repeatType,
                repeatDays: task.repeatDays, repeatTimes: task.repeatTimes,
                project: task.project), to: task, context: context)
        }
        // ③ 任务侧:日历里删掉事件 = 删掉任务(用户确认过的语义,不可撤销)
        for uuid in plan.deleteTaskUUIDs {
            guard let task = tasksByUUID[uuid] else { continue }
            TaskActions.delete(task, context: context)
        }

        // ④ 账本:plan 里已经算好的那些 + 这次新建出来的
        var ledger = plan.records
        for mirror in plan.createEvents {
            guard let id = created[mirror.uuid] else { continue }
            ledger.append(.from(mirror, eventID: id, isOwnCalendar: true))
        }
        CalendarSyncLedger.save(ledger)
        WidgetBridge.sync(context: context)
    }

    /// 把别人家日历里的一条事件「转为任务」:建任务 + 记进账本(`isOwnCalendar`
    /// 为 false)。从这一刻起这条也进入双向——之后在日历里改时间会回写进任务,
    /// 在日历里删掉会连任务一起删;反过来 lodo 这边改了会改那条事件,但
    /// **任务被删时不删它**(那是用户自己的日程,见 CalendarSyncPlanner)。
    @discardableResult
    static func importEvent(_ event: CalendarEvent, context: ModelContext) -> TaskItem {
        let minutes = max(0, Int(event.end.timeIntervalSince(event.start) / 60))
        let task = TaskActions.create(ParsedTask(
            title: event.title, remindAt: event.start, allDay: event.isAllDay,
            durationMinutes: event.isAllDay ? 0 : minutes,
            repeatType: .none, repeatDays: [], repeatTimes: []), context: context)
        CalendarSyncLedger.append(.from(event, taskUUID: task.uuid, isOwnCalendar: false))
        WidgetBridge.sync(context: context)
        return task
    }
}
