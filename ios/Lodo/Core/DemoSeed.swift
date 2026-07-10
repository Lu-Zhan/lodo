import Foundation
import SwiftData
import LodoCore

#if DEBUG
/// 调试用演示数据:`--demo-data` 启动参数触发,覆盖到期卡片、两阶段、
/// 重复事项、已完成等 UI 状态,便于模拟器截图验证。
enum DemoSeed {
    @MainActor
    static func populateIfRequested(_ container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("--demo-data") else { return }
        let context = container.mainContext
        try? context.delete(model: TaskItem.self)
        let now = Date()

        // 已到期:普通事项,过期 20 分钟
        context.insert(TaskItem(title: "给妈妈回电话",
                                remindAt: now.addingTimeInterval(-20 * 60)))
        // 已到期:有时长事项,start 阶段
        context.insert(TaskItem(title: "开周会", remindAt: now.addingTimeInterval(-5 * 60),
                                durationMinutes: 60))
        // 未到期:今天晚些
        context.insert(TaskItem(title: "取快递", remindAt: now.addingTimeInterval(3 * 3600)))
        // 未到期:明天全天
        context.insert(TaskItem(title: "交报告",
                                remindAt: AppSettings.time(
                                    AppSettings.allDayTime,
                                    on: now.addingTimeInterval(24 * 3600)),
                                allDay: true))
        // 重复:每天早晚吃药
        let med = TaskItem(title: "吃药", remindAt: now, repeatType: .daily,
                           repeatTimes: ["09:00", "21:00"])
        var d = med.data
        if let next = Scheduler.nextOccurrence(d, after: now) {
            d.remindAt = next
            d.nextRemindAt = next
            med.apply(d)
        }
        context.insert(med)
        // 已完成
        context.insert(TaskItem(title: "预约体检", remindAt: now.addingTimeInterval(-24 * 3600),
                                status: .done, doneAt: now.addingTimeInterval(-3600)))
        try? context.save()
    }
}
#endif
