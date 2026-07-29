import Foundation

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
}
