#if os(iOS)
import UIKit

/// 按键震动。用 `.soft`(比 `.light` 更收敛、不发硬),强度跟主 app 设置里的滑块;
/// 不同的键轻重不一样:连删最轻、还限了频,不然按住删除会嗡成一片。
/// 系统只在开了「完全访问」时让键盘扩展震动,没开时这些调用是空操作。
@MainActor
final class KeyboardHaptics {
    enum Event {
        case key, space, delete, repeatDelete, candidate

        var scale: CGFloat {
            switch self {
            case .key, .candidate: 1.0
            case .space: 0.85
            case .delete: 0.8
            case .repeatDelete: 0.35
            }
        }
    }

    var enabled = true
    /// 0.1…1.0,由扩展从 App Group 读来设。
    var intensity: CGFloat = 0.6
    private lazy var generator = UIImpactFeedbackGenerator(style: .soft)
    private var lastRepeat: TimeInterval = 0

    /// 键盘弹出时先预热,第一下按键就跟手。
    func prepare() {
        guard enabled else { return }
        generator.prepare()
    }

    func play(_ event: Event) {
        guard enabled else { return }
        if event == .repeatDelete {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastRepeat >= 0.1 else { return }
            lastRepeat = now
        }
        generator.impactOccurred(intensity: min(max(intensity * event.scale, 0), 1))
        generator.prepare() // 为下一下准备(紧挨着触发前 prepare 不管用)
    }
}
#endif
