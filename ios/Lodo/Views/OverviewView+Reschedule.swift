import SwiftUI
import LodoCore

/// 通知"改期"按钮交接:目标事项可能不在可视区域内(总览是仪表盘式的短列表,
/// 但仍不保证一定挂载),所以这条路径不复用 TaskRowView 内部滑动触发的改期
/// 状态(那是每一行自己的 @State),而是走一个独立于行的顶部横幅——请求/
/// 应用的核心逻辑复用 TaskActions,和 TaskRowView 内部走的是同一套。
extension OverviewView {
    /// 通知"改期"按钮交接:找到对应事项、发起改期请求。总览本来就同时显示
    /// 全部到期项,不需要像待办 tab 那样先切筛选态。
    func consumeReschedule(_ uuid: String?) {
        guard let uuid, let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { return }
        rescheduleRequestUUID = nil
        requestNotificationReschedule(task)
    }

    /// 请求逾期事项的 AI 改期候选(按需调用;新请求取消旧请求,返回时校验仍是当前卡)。
    func requestNotificationReschedule(_ task: TaskItem) {
        notificationRescheduleTask?.cancel()
        let uuid = task.uuid
        notificationRescheduleLoading = uuid
        notificationReschedule = nil
        rescheduleError = nil
        notificationRescheduleTask = Task {
            do {
                let candidates = try await TaskActions.requestReschedule(for: task)
                guard !Task.isCancelled, notificationRescheduleLoading == uuid else { return }
                withAnimation(.snappy) {
                    notificationReschedule = (task, candidates)
                }
            } catch {
                guard !Task.isCancelled, notificationRescheduleLoading == uuid,
                      !(error is CancellationError) else { return }
                rescheduleError = error.localizedDescription
            }
            if notificationRescheduleLoading == uuid { notificationRescheduleLoading = nil }
        }
    }

    /// 应用通知交接横幅里选中的改期候选。
    func applyNotificationReschedule(_ date: Date) {
        guard let task = notificationReschedule?.task else { return }
        Haptics.success()
        TaskActions.applyReschedule(task, to: date, context: context)
        withAnimation(.snappy) {
            notificationReschedule = nil
        }
    }
}
