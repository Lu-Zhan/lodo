import Foundation
#if os(iOS)
import UIKit
#endif

/// 滑动操作的振动反馈;受设置里的「振动反馈」开关控制,macOS 为空实现。
enum Haptics {
    /// 完成/未完成等成功类操作。
    static func success() {
        #if os(iOS)
        guard AppSettings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// 删除等普通操作。
    static func impact() {
        #if os(iOS)
        guard AppSettings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
