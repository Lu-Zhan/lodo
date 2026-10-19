import Foundation

/// 「用闹钟提醒」的对账逻辑(纯函数,不 import AlarmKit,单测 `TaskAlarmPlanTests`)。
///
/// 规则:
/// - 只给**还没完成**、开了闹钟、原定时间(`remindAt`)还在未来的任务排闹钟——闹钟只响
///   原定时间那一次,之后的纠缠交给通知链(稍等/忽略只挪 nextRemindAt,不再拉闹钟)。
/// - 免打扰时段照样生效:深夜的闹钟挪到时段结束,和通知链同一个口径(`Scheduler.applyQuietHours`)。
/// - 一次最多排 `limit` 个(按时间从近到远),多出来的等前面的响完、下次对账再排。
/// - 系统里已有的闹钟:时间对得上就不动,对不上先撤再排;正在响的不撤(任务还没完成时)。
public enum TaskAlarmPlan {
    public static let limit = 20

    public struct Candidate: Equatable {
        public var id: UUID
        public var title: String
        public var remindAt: Date
        public var pending: Bool
        public var alarm: Bool

        public init(id: UUID, title: String, remindAt: Date, pending: Bool, alarm: Bool) {
            self.id = id
            self.title = title
            self.remindAt = remindAt
            self.pending = pending
            self.alarm = alarm
        }
    }

    public struct Desired: Equatable {
        public var id: UUID
        public var title: String
        public var fireDate: Date
    }

    /// 系统里已有的一个闹钟(只关心对账要用的两样)。
    public struct Existing: Equatable {
        public var id: UUID
        /// nil = 不是固定时刻的闹钟(不该出现,当作对不上处理)。
        public var fireDate: Date?
        public var alerting: Bool

        public init(id: UUID, fireDate: Date?, alerting: Bool) {
            self.id = id
            self.fireDate = fireDate
            self.alerting = alerting
        }
    }

    public struct Changes: Equatable {
        public var cancel: [UUID] = []
        public var schedule: [Desired] = []
    }

    public static func desired(
        _ candidates: [Candidate], now: Date,
        quietStart: String = "", quietEnd: String = "", quietEnabled: Bool = false,
        limit: Int = TaskAlarmPlan.limit
    ) -> [Desired] {
        candidates
            .filter { $0.pending && $0.alarm }
            .map { candidate in
                Desired(id: candidate.id, title: candidate.title,
                        fireDate: Scheduler.applyQuietHours(
                            candidate.remindAt, quietStart: quietStart, quietEnd: quietEnd,
                            enabled: quietEnabled))
            }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(limit)
            .map { $0 }
    }

    /// 已有闹钟 → 要撤的 + 要排的。标题改了也要重排(闹钟上显示的是标题)。
    /// `titles`:已有闹钟当初排的标题(app 自己记的,系统不回传);没记的视为对不上。
    public static func changes(desired: [Desired], existing: [Existing],
                               titles: [UUID: String] = [:],
                               pendingIDs: Set<UUID> = []) -> Changes {
        var result = Changes()
        let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<UUID>()
        for alarm in existing {
            if let target = wanted[alarm.id],
               let fire = alarm.fireDate,
               abs(fire.timeIntervalSince(target.fireDate)) < 1,
               titles[alarm.id] == target.title {
                kept.insert(alarm.id)
                continue
            }
            // 正在响、任务也还没完成:让它响完(撤掉等于替用户按了停止)。
            if alarm.alerting && pendingIDs.contains(alarm.id) {
                kept.insert(alarm.id)
                continue
            }
            result.cancel.append(alarm.id)
        }
        result.schedule = desired.filter { !kept.contains($0.id) }
        return result
    }
}
