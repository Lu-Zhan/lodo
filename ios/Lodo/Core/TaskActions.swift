import Foundation
import SwiftData
import LodoCore

/// 待办的落库/AI 改期逻辑,`TodoListView`(经 `TaskRowView`)和 `OverviewView`
/// 共用,避免"改一处漏一处"(尤其 NotificationManager.rebuild/WidgetBridge.sync
/// 这类容易漏掉的连带更新)。不依赖任何 View 的 @State,`context` 都是显式传入。
@MainActor
enum TaskActions {
    /// 新建落库(表单保存、AI 新建、演示数据播种共用)。和 `apply` 一样把
    /// NotificationManager.rebuild 这类容易漏掉的连带
    /// 更新收在一处——之前这段只存在于 `TodoListView.saveNew`,agent 路由从
    /// TodoListView 拆到 AgentHostView 之后两边都要用,所以提上来。
    @discardableResult
    static func create(_ parsed: ParsedTask, attachment: TaskAttachment? = nil,
                       context: ModelContext) -> TaskItem {
        let task = TaskItem(
            title: parsed.title, remindAt: parsed.remindAt, allDay: parsed.allDay,
            repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
            repeatTimes: parsed.repeatTimes, project: parsed.project)
        task.attachment = attachment
        context.insert(task)
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
        return task
    }

    static func apply(_ parsed: ParsedTask, to task: TaskItem, context: ModelContext) {
        task.title = parsed.title
        task.remindAt = parsed.remindAt
        task.allDay = parsed.allDay
        task.repeatTypeRaw = parsed.repeatType.rawValue
        task.repeatDays = parsed.repeatDays
        task.repeatTimes = parsed.repeatTimes
        task.project = parsed.project
        task.phaseRaw = TaskPhase.start.rawValue
        task.nextRemindAt = parsed.remindAt
        task.ignoreStreak = 0
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    static func complete(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.complete(task, context: context)
    }

    static func delete(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.cancelChain(for: task.uuid)
        context.delete(task)
        try? context.save()
        WidgetBridge.sync(context: context)
        CalendarSync.sync(context: context)
    }

    /// 置顶 / 取消置顶(「重要的事」)。只动展示字段,不碰提醒链。
    static func togglePin(_ task: TaskItem, context: ModelContext) {
        task.pinned.toggle()
        task.pinnedAt = task.pinned ? Date() : nil
        try? context.save()
        WidgetBridge.sync(context: context)
    }

    static func snooze(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.snooze(task, context: context)
    }

    static func ignore(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.ignore(task, context: context)
    }

    /// 逾期事项的 AI 改期候选(只读,不落库)。
    static func requestReschedule(for task: TaskItem) async throws -> [(label: String, date: Date)] {
        try await DeepSeekClient.suggestReschedule(
            title: task.title, remindAt: task.remindAt, isRecurring: task.isRecurring)
    }

    /// 应用改期候选:非重复事项连 remindAt 一起改,重复事项只顺延本次。
    static func applyReschedule(_ task: TaskItem, to date: Date, context: ModelContext) {
        guard task.status == .pending else { return }
        if !task.isRecurring { task.remindAt = date }
        task.nextRemindAt = date
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }
}
