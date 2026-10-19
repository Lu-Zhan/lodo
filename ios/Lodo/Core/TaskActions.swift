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
        // 收集里的事项没有时间,也就没有闹钟。
        task.alarm = parsed.isInbox ? false : (parsed.alarm ?? false)
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
        if let alarm = parsed.alarm { task.alarm = alarm }
        if parsed.isInbox { task.alarm = false }
        task.phaseRaw = TaskPhase.start.rawValue
        task.nextRemindAt = parsed.remindAt
        task.ignoreStreak = 0
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }

    static func complete(_ task: TaskItem, context: ModelContext) {
        NotificationManager.shared.complete(task, context: context)
    }

    /// 完成一次、记下撤销所需的快照(总览卡片上点了圆圈、再点一下改回来)。
    /// 重复事项完成一次是"顺延 + 插一条已完成历史",所以撤销要用完成前的整份快照
    /// 覆盖回去并删掉那条历史——同 AI 批量撤销的 `UndoOp.completed`。
    struct CompletionUndo {
        let before: BackupTask
        /// 重复事项完成一次插入的历史记录;一次性事项为 nil(它自己变成 done)。
        let historyUUID: UUID?
        /// 完成的时刻:用药提醒任务这一下记的服药按它找出来,撤销时一起删。
        var completedAt = Date()
    }

    @discardableResult
    static func completeUndoably(_ task: TaskItem, context: ModelContext) -> CompletionUndo {
        let before = task.backup
        let completedAt = Date()
        let history = NotificationManager.shared.complete(task, context: context)
        return CompletionUndo(before: before, historyUUID: history?.uuid, completedAt: completedAt)
    }

    static func undo(_ undo: CompletionUndo, context: ModelContext) {
        let uuid = undo.before.uuid
        MedicationStore.removeDoses(fromTask: uuid, since: undo.completedAt, context: context)
        if let task = (try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.uuid == uuid })))?.first {
            undo.before.apply(to: task)
            NotificationManager.shared.rebuild(for: task)
        }
        if let historyUUID = undo.historyUUID,
           let history = (try? context.fetch(FetchDescriptor<TaskItem>(
               predicate: #Predicate<TaskItem> { $0.uuid == historyUUID })))?.first {
            context.delete(history)
        }
        try? context.save()
        WidgetBridge.sync(context: context)
        CalendarSync.sync(context: context)
    }

    /// 已完成的事项恢复成待办:回到 start 阶段,提醒时间取原定时间(已过期会直接进到期卡)。
    /// 没有完成前快照时用(已完成列表、总览里不是在这次打开时完成的那几条)。
    static func restore(_ task: TaskItem, context: ModelContext) {
        task.statusRaw = TaskStatus.pending.rawValue
        task.phaseRaw = TaskPhase.start.rawValue
        task.doneAt = nil
        task.nextRemindAt = task.remindAt
        task.ignoreStreak = 0
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
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

    /// 打开 / 关掉闹钟提醒。只动这个字段,闹钟在 `WidgetBridge.sync` 那一轮里对账。
    static func toggleAlarm(_ task: TaskItem, context: ModelContext) {
        task.alarm.toggle()
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
        // 用药提醒不发给 AI(健康数据):给两个本地候选。
        if task.isMedicationReminder {
            let language = AppSettings.language
            let now = Date()
            return [
                (String(localized: "30 分钟后", bundle: .appLanguage(), locale: language.locale),
                 now.addingTimeInterval(30 * 60)),
                (String(localized: "1 小时后", bundle: .appLanguage(), locale: language.locale),
                 now.addingTimeInterval(60 * 60)),
            ]
        }
        return try await DeepSeekClient.suggestReschedule(
            title: task.title, remindAt: task.remindAt, isRecurring: task.isRecurring)
    }

    /// 应用改期候选:非重复事项连 remindAt 一起改,重复事项只顺延本次。
    static func applyReschedule(_ task: TaskItem, to date: Date, context: ModelContext) {
        guard task.status == .pending, !task.isInbox else { return }
        if !task.isRecurring { task.remindAt = date }
        task.nextRemindAt = date
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }
}
