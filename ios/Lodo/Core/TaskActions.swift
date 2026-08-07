import Foundation
import SwiftData
import LodoCore

/// 待办的落库/AI 改期逻辑,`TodoListView`(经 `TaskRowView`)和 `OverviewView`
/// 共用,避免"改一处漏一处"(尤其 NotificationManager.rebuild/WidgetBridge.sync
/// 这类容易漏掉的连带更新)。不依赖任何 View 的 @State,`context` 都是显式传入。
@MainActor
enum TaskActions {
    static func apply(_ parsed: ParsedTask, to task: TaskItem, context: ModelContext) {
        task.title = parsed.title
        task.remindAt = parsed.remindAt
        task.durationMinutes = parsed.durationMinutes
        task.allDay = parsed.allDay
        task.repeatTypeRaw = parsed.repeatType.rawValue
        task.repeatDays = parsed.repeatDays
        task.repeatTimes = parsed.repeatTimes
        task.project = parsed.project
        task.phaseRaw = TaskPhase.start.rawValue
        task.nextRemindAt = parsed.remindAt
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
    }

    /// 完成 + 实际耗时采样判断:仅真正"完成一次"(非两阶段的"开始了")且命中
    /// 采样条件时返回 (title, planned),调用方据此把耗时问询轻量条排队展示;
    /// 否则返回 nil。
    @discardableResult
    static func complete(_ task: TaskItem, context: ModelContext) -> (title: String, planned: Int)? {
        let title = task.title
        let planned = task.durationMinutes
        // phase==start 且有时长的这次点按是"开始了",不算完成
        let isFinishing = !(task.phase == .start && task.durationMinutes > 0)
        NotificationManager.shared.complete(task, context: context)
        if isFinishing, planned > 0,
           DurationMemory.shouldAskActual(title: title, planned: planned) {
            return (title, planned)
        }
        return nil
    }

    static func delete(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.cancelChain(for: task.uuid)
        context.delete(task)
        try? context.save()
        WidgetBridge.sync(context: context)
    }

    static func snooze(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.snooze(task, context: context)
    }

    /// 逾期事项的 AI 改期候选(只读,不落库)。
    static func requestReschedule(for task: TaskItem) async throws -> [(label: String, date: Date)] {
        try await DeepSeekClient.suggestReschedule(
            title: task.title, remindAt: task.remindAt,
            durationMinutes: task.durationMinutes, isRecurring: task.isRecurring)
    }

    /// 应用改期候选:非重复事项连 remindAt 一起改,重复事项只顺延本次。
    static func applyReschedule(_ task: TaskItem, to date: Date, context: ModelContext) {
        guard task.status == .pending else { return }
        if !task.isRecurring { task.remindAt = date }
        task.nextRemindAt = date
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    static func durationChips(planned: Int) -> [Int] {
        let lower = max(5, (planned / 2 + 2) / 5 * 5)
        let upper = (planned * 3 / 2 + 2) / 5 * 5
        var chips: [Int] = []
        for value in [lower, planned, upper] where !chips.contains(value) {
            chips.append(value)
        }
        return chips
    }
}
