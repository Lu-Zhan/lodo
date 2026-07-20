import SwiftUI
import LodoCore

/// 到期卡片的 AI 改期候选。
extension TodoListView {
    /// 通知"改期"按钮交接:找到对应事项、跳到它所在日期、直接发起改期请求,
    /// 等同于用户在到期卡片上手动点了一次"改期"。
    func consumeReschedule(_ uuid: String?) {
        guard let uuid, let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { return }
        rescheduleRequestUUID = nil
        selectedDate = Calendar.current.startOfDay(for: task.nextRemindAt)
        requestReschedule(task)
    }

    /// 请求逾期事项的 AI 改期候选(按需调用;新请求取消旧请求,返回时校验仍是当前卡)。
    func requestReschedule(_ task: TaskItem) {
        rescheduleTask?.cancel()
        let uuid = task.uuid.uuidString
        rescheduleLoading = uuid
        reschedule = nil
        rescheduleError = nil
        let title = task.title
        let remindAt = task.remindAt
        let duration = task.durationMinutes
        let recurring = task.isRecurring
        rescheduleTask = Task {
            do {
                let candidates = try await DeepSeekClient.suggestReschedule(
                    title: title, remindAt: remindAt,
                    durationMinutes: duration, isRecurring: recurring)
                guard !Task.isCancelled, rescheduleLoading == uuid else { return }
                withAnimation(.snappy) {
                    reschedule = (uuid, candidates)
                }
            } catch {
                guard !Task.isCancelled, rescheduleLoading == uuid,
                      !(error is CancellationError) else { return }
                rescheduleError = error.localizedDescription
            }
            if rescheduleLoading == uuid { rescheduleLoading = nil }
        }
    }

    /// 应用改期候选:非重复事项连 remindAt 一起改,重复事项只顺延本次。
    func applyReschedule(_ task: TaskItem, to date: Date) {
        Haptics.success()
        guard task.status == .pending else {
            reschedule = nil
            return
        }
        if !task.isRecurring { task.remindAt = date }
        task.nextRemindAt = date
        withAnimation(.snappy) {
            reschedule = nil
        }
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }
}
