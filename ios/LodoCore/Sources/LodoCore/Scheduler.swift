import Foundation

/// 提醒调度核心逻辑,移植自 web/lodo/scheduler.py。
/// 纯函数操作 TaskData,由调用方负责持久化与通知重排。
public enum Scheduler {

    /// 返回此刻应当弹出提醒的事项。
    public static func dueTasks(_ tasks: [TaskData], now: Date) -> [TaskData] {
        tasks.filter { $0.isDue(now: now) }
    }

    /// 弹出提醒的同时把下次提醒自动顺延——忽略提醒也会在间隔后再次提醒。
    public static func markNotified(_ task: inout TaskData, now: Date, snoozeMinutes: Int) {
        task.nextRemindAt = now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
    }

    /// 用户点"稍等"。
    public static func snooze(_ task: inout TaskData, now: Date, snoozeMinutes: Int) {
        task.nextRemindAt = now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
    }

    /// 重复事项在 after 之后的下一次提醒时间。
    /// 每日:每天在 repeatTimes 各提醒一次;每周:仅在 repeatDays 选中的周几提醒。
    public static func nextOccurrence(
        _ task: TaskData, after: Date, calendar: Calendar = .current
    ) -> Date? {
        guard task.isRecurring, !task.repeatTimes.isEmpty else { return nil }
        if task.repeatType == .weekly && task.repeatDays.isEmpty { return nil }
        let days: Set<Int> = task.repeatType == .daily ? Set(0..<7) : Set(task.repeatDays)
        let times = task.repeatTimes.sorted()
        for offset in 0..<8 {  // 最多一周内必有下一次
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: after)) else { continue }
            // Calendar.weekday: 1=周日…7=周六 → 转为 0=周一…6=周日
            let pyWeekday = (calendar.component(.weekday, from: day) + 5) % 7
            guard days.contains(pyWeekday) else { continue }
            for hhmm in times {
                let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2,
                      let candidate = calendar.date(bySettingHour: parts[0], minute: parts[1],
                                                    second: 0, of: day) else { continue }
                if candidate > after { return candidate }
            }
        }
        return nil
    }

    /// 用户对提醒做出肯定响应。返回 true 表示完成了一次(或整个)事项。
    ///
    /// - 时长 > 0 且处于开始阶段:表示"开始做了",转入结束阶段,
    ///   在实际开始时间 + 时长后提醒确认完成,返回 false。
    /// - 其余情况即完成:一次性事项标记 done;重复事项排到下一次提醒。
    public static func advance(
        _ task: inout TaskData, now: Date, calendar: Calendar = .current
    ) -> Bool {
        if task.phase == .start && task.durationMinutes > 0 {
            task.phase = .end
            task.nextRemindAt = now.addingTimeInterval(TimeInterval(task.durationMinutes * 60))
            return false
        }
        if let next = nextOccurrence(task, after: now, calendar: calendar) {
            task.phase = .start
            task.remindAt = next
            task.nextRemindAt = next
        } else {
            task.status = .done
            task.doneAt = now
        }
        return true
    }
}
