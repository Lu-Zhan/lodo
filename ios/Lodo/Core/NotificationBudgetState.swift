import Foundation

/// refreshAll 每次计算后的"预算外任务数"(pending 事项数超过通知链全局预算时,
/// 排不到通知的部分),供 UI 展示提示条。只在同时 48+ 个 pending 事项时非零,
/// 属于极端场景,不需要持久化,重启或下次 refreshAll 前保持上次的值即可。
@Observable final class NotificationBudgetState {
    static let shared = NotificationBudgetState()
    var overflowCount: Int = 0
}
