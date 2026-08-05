import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 共享的圆角数值,替代各处随手写的字面量(之前 10/12/16 混用,没有统一
/// 的视觉尺度)。三级足够覆盖这个 app 的形状语言:chip(胶囊感强的小标签)、
/// card(卡片/行容器)、bubble(聊天气泡,比卡片更圆润)。
enum DesignMetrics {
    static let chipRadius: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 18
    /// AI 助手对话列表侧栏(窄屏抽屉 / 宽屏常驻列)的固定宽度。
    static let sidebarWidth: CGFloat = 300
    /// 侧栏展开时被推移缩小的主内容圆角——刻意贴近真机屏幕圆角(而不是
    /// cardRadius 那种小圆角),让被推开的内容看起来像一整块"缩小的设备屏幕"。
    static let deviceCornerRadius: CGFloat = 44

    /// 系统"减弱动态效果"辅助功能开关。之前全仓库没有任何地方读过这个值,
    /// 所有弹簧/过渡动画不分青红皂白照放——`Animation.lodoAware(_:)` 统一
    /// 收敛在这一处判断,调用方不用各自 `#if os(iOS)` 分支。
    static var reduceMotionEnabled: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #elseif os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }
}

extension Animation {
    /// 侧栏/抽屉类展开收起统一用这一条弹簧曲线——之前窄屏拖拽版侧栏用
    /// spring、宽屏常驻版同一个"展开/收起"交互却用 easeInOut,松紧手感不一致。
    static let lodoSidebar = Animation.spring(response: 0.35, dampingFraction: 0.86)
    /// 输入框内控件切换(麦克风⇄发送)、搜索框展开收起等轻量场景。
    static let lodoQuickFade = Animation.easeInOut(duration: 0.2)

    /// 遵守"减弱动态效果":开启时退化成一个几乎瞬时但仍然平滑的短过渡
    /// (不是直接去掉动画——纯状态硬切在有过渡的界面里反而更突兀、更容易让人
    /// 以为卡了一下),调用方原有的 value 触发逻辑不用改。
    static func lodoAware(_ animation: Animation) -> Animation {
        DesignMetrics.reduceMotionEnabled ? .linear(duration: 0.05) : animation
    }
}
