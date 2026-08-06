import Foundation
import LodoCore
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

    /// 有后果、值得多提醒一下的操作(如不可撤销的删除)。
    static func warning() {
        #if os(iOS)
        guard AppSettings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// impact() 的力度档位;调用方(TaskRowView 等)iOS/macOS 共用,不能在签名里
    /// 直接暴露 UIKit 类型,所以这里包一层平台无关的 enum。
    enum ImpactStyle {
        case light, medium, heavy
    }

    /// 删除等普通操作,默认 .medium 与原有调用方行为一致;轻量操作(如稍等)
    /// 可传 .light。
    static func impact(_ style: ImpactStyle = .medium) {
        #if os(iOS)
        guard AppSettings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style.uiKitStyle).impactOccurred()
        #endif
    }
}

#if os(iOS)
private extension Haptics.ImpactStyle {
    var uiKitStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}
#endif
