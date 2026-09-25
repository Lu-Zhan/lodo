import Foundation

/// 一条已经建立起来的"任务 ↔ 日历事件"镜像关系,外加**上次对平时双方的样子**。
///
/// 这份快照是双向同步的全部依据:下一次对账时,任务和当时不一样 = 这边改过,
/// 事件和当时不一样 = 那边改过。没有它就只能靠时间戳猜,而 SwiftData 的
/// `TaskItem` 本来没有"改动时间"这一列(给每个改动点补一列 updatedAt 要动十几处,
/// 漏一处就悄悄同步错方向)。
public struct CalendarSyncRecord: Codable, Equatable, Sendable {
    public var taskUUID: UUID
    public var eventID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// 这条事件在不在 lodo 自己那本日历里。false = 用户在别的日历里的日程被
    /// 「转为任务」认领过来的——**那条事件归用户所有,我们只改不删**。
    public var isOwnCalendar: Bool

    public init(taskUUID: UUID, eventID: String, title: String, start: Date, end: Date,
                isAllDay: Bool, isOwnCalendar: Bool) {
        self.taskUUID = taskUUID
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isOwnCalendar = isOwnCalendar
    }

    func matches(_ mirror: CalendarTaskMirror) -> Bool {
        title == mirror.title && start == mirror.start && end == mirror.end
            && isAllDay == mirror.isAllDay
    }

    func matches(_ event: CalendarEvent) -> Bool {
        title == event.title && start == event.start && end == event.end
            && isAllDay == event.isAllDay
    }

    public static func from(_ mirror: CalendarTaskMirror, eventID: String,
                            isOwnCalendar: Bool) -> CalendarSyncRecord {
        CalendarSyncRecord(taskUUID: mirror.uuid, eventID: eventID, title: mirror.title,
                           start: mirror.start, end: mirror.end, isAllDay: mirror.isAllDay,
                           isOwnCalendar: isOwnCalendar)
    }

    public static func from(_ event: CalendarEvent, taskUUID: UUID,
                            isOwnCalendar: Bool) -> CalendarSyncRecord {
        CalendarSyncRecord(taskUUID: taskUUID, eventID: event.id, title: event.title,
                           start: event.start, end: event.end, isAllDay: event.isAllDay,
                           isOwnCalendar: isOwnCalendar)
    }
}

/// 事件那边改了之后要回写进任务的值。
public struct CalendarTaskUpdate: Equatable, Sendable {
    public let uuid: UUID
    public let title: String
    public let start: Date
    public let durationMinutes: Int
    public let isAllDay: Bool
}

/// 一次对账要做的事。纯数据,应用它的是 app 层(`CalendarSync`)。
public struct CalendarSyncPlan: Equatable, Sendable {
    /// 还没上过日历的任务 → 新建事件(事件 id 要等 EventKit 存完才知道,
    /// 所以这几条的账本由 app 层补)。
    public var createEvents: [CalendarTaskMirror] = []
    /// 任务这边改了(或重复事项被人在日历里改了)→ 把事件改回和任务一致。
    public var updateEvents: [(eventID: String, mirror: CalendarTaskMirror)] = []
    /// 任务没了/完成了 → 删掉我们自己那本里的事件(别人家日历的不删)。
    public var deleteEventIDs: [String] = []
    /// 事件那边改了 → 回写进任务。
    public var updateTasks: [CalendarTaskUpdate] = []
    /// 事件被人在日历里删了 → 删掉对应任务(用户确认过的语义,不可撤销)。
    public var deleteTaskUUIDs: [UUID] = []
    /// 对账后仍然成立的那些镜像关系(新建的那批由 app 层补进来)。
    public var records: [CalendarSyncRecord] = []

    public var isEmpty: Bool {
        createEvents.isEmpty && updateEvents.isEmpty && deleteEventIDs.isEmpty
            && updateTasks.isEmpty && deleteTaskUUIDs.isEmpty
    }

    public static func == (lhs: CalendarSyncPlan, rhs: CalendarSyncPlan) -> Bool {
        lhs.createEvents == rhs.createEvents
            && lhs.updateEvents.map(\.eventID) == rhs.updateEvents.map(\.eventID)
            && lhs.updateEvents.map(\.mirror) == rhs.updateEvents.map(\.mirror)
            && lhs.deleteEventIDs == rhs.deleteEventIDs
            && lhs.updateTasks == rhs.updateTasks
            && lhs.deleteTaskUUIDs == rhs.deleteTaskUUIDs
            && lhs.records == rhs.records
    }
}

/// 双向对账的纯逻辑。**不碰 EventKit、不碰 SwiftData**——给它上次的账本、
/// 现在的任务、现在的事件,它算出"两边各要改什么",怎么做由 app 层执行。
/// 这样这套判断(谁改了、冲突了算谁的、什么时候算被删)能离线单测。
public enum CalendarSyncPlanner {

    /// - Parameters:
    ///   - records: 上次对平后的账本。
    ///   - tasks: 现在库里**未完成**的任务镜像(完成的不在里面,等同于"任务没了")。
    ///   - events: 现在窗口内、和我们有关的事件(自家日历的全部 + 账本里认领过的
    ///     别人家日历那几条),按事件 id 索引。
    ///   - claimedUUIDs: 自家日历里事件 URL 上写着的任务 uuid(`eventID → uuid`),
    ///     用来在账本丢了(换设备、删过文件)之后重新认领,不至于把事件重写一遍。
    ///   - window: 这次查询覆盖的时间范围。**窗口外查不到 ≠ 被删**,这个区分很要命:
    ///     不判断的话,把某条任务改到三个月后、或者往前翻到旧周,都会被当成"事件
    ///     被删了"而把任务一起删掉。
    public static func plan(records: [CalendarSyncRecord],
                            tasks: [CalendarTaskMirror],
                            events: [CalendarEvent],
                            claimedUUIDs: [String: UUID] = [:],
                            window: ClosedRange<Date>) -> CalendarSyncPlan {
        var plan = CalendarSyncPlan()
        let tasksByUUID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.uuid, $0) })
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var handledTasks: Set<UUID> = []
        var handledEvents: Set<String> = []

        for record in records {
            handledTasks.insert(record.taskUUID)
            handledEvents.insert(record.eventID)
            let task = tasksByUUID[record.taskUUID]
            let event = eventsByID[record.eventID]

            switch (task, event) {
            case let (.some(task), .some(event)):
                let taskChanged = !record.matches(task)
                let eventChanged = !record.matches(event)
                if taskChanged {
                    // 两边都改了也走这支:**任务这边赢**。lodo 才是任务的所有者,
                    // 而且提醒阶段/稍等/重复规则这些语义只有 lodo 有,事件那边
                    // 表达不出来,拿它盖掉任务会丢信息。
                    plan.updateEvents.append((eventID: record.eventID, mirror: task))
                    plan.records.append(.from(task, eventID: record.eventID,
                                              isOwnCalendar: record.isOwnCalendar))
                } else if eventChanged {
                    if task.isRecurring {
                        // 重复事项只推不拉:一次发生改不了整条规则,推回原样。
                        plan.updateEvents.append((eventID: record.eventID, mirror: task))
                        plan.records.append(.from(task, eventID: record.eventID,
                                                  isOwnCalendar: record.isOwnCalendar))
                    } else {
                        plan.updateTasks.append(CalendarTaskUpdate(
                            uuid: record.taskUUID, title: event.title, start: event.start,
                            durationMinutes: max(0, Int(event.end.timeIntervalSince(event.start) / 60)),
                            isAllDay: event.isAllDay))
                        plan.records.append(.from(event, taskUUID: record.taskUUID,
                                                  isOwnCalendar: record.isOwnCalendar))
                    }
                } else {
                    plan.records.append(record)
                }

            case (.some, .none):
                // 事件不见了。**只有当它本该在这次查询范围内时**才算被删——
                // 否则是窗口没覆盖到,留着账本下次再说。
                if window.contains(record.start) {
                    plan.deleteTaskUUIDs.append(record.taskUUID)
                } else {
                    plan.records.append(record)
                }

            case let (.none, .some(event)):
                // 任务没了(在 lodo 里删掉或完成了)。自家日历的事件跟着删;
                // 别人家日历那条是用户自己的日程,只解除关系,绝不替他删。
                if record.isOwnCalendar {
                    plan.deleteEventIDs.append(event.id)
                }

            case (.none, .none):
                break  // 两边都没了,账本这条直接作废
            }
        }

        // 账本里没有的任务 → 还没上过日历,新建。
        for task in tasks where !handledTasks.contains(task.uuid) {
            plan.createEvents.append(task)
        }

        // 自家日历里带着 lodo URL、账本却不认识的事件:换设备或账本文件丢了之后
        // 会出现。任务还在就把关系认回来(顺手按任务推一次,免得两边不一致);
        // 任务已经没了就是孤儿,删掉。
        for (eventID, uuid) in claimedUUIDs where !handledEvents.contains(eventID) {
            guard let event = eventsByID[eventID] else { continue }
            if let task = tasksByUUID[uuid] {
                plan.createEvents.removeAll { $0.uuid == uuid }
                if !CalendarSyncRecord.from(task, eventID: eventID, isOwnCalendar: true)
                    .matches(event) {
                    plan.updateEvents.append((eventID: eventID, mirror: task))
                }
                plan.records.append(.from(task, eventID: eventID, isOwnCalendar: true))
            } else {
                plan.deleteEventIDs.append(eventID)
            }
        }
        return plan
    }
}
