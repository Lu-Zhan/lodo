import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 共享的圆角数值,替代各处随手写的字面量(之前 10/12/16 混用,没有统一
/// 的视觉尺度)。四级覆盖这个 app 的形状语言:chip(胶囊感强的小标签)、
/// card(卡片/行容器)、bubble(聊天气泡,比卡片更圆润)、composer(AI 输入栏
/// 合并玻璃卡片,比 bubble 更圆)。
enum DesignMetrics {
    static let chipRadius: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let bubbleRadius: CGFloat = 18
    /// AI 助手输入栏合并玻璃卡片的圆角——比 bubbleRadius 更圆润(更接近
    /// "squircle"手感),不到 deviceCornerRadius 那种整机屏幕圆角。
    static let composerRadius: CGFloat = 26
    /// 应用导航侧栏(窄屏抽屉 / 宽屏常驻列)的固定宽度。
    static let sidebarWidth: CGFloat = 300
    /// 窄屏抽屉「从左边缘右滑唤出」的可触发带宽。刻意做窄:待办/记忆/总览的
    /// 列表行本身有滑动操作(完成/改期/稍等/删除、转为待办),整页横滑手势会
    /// 和它们抢,只有贴着屏幕左边缘这一条窄带才当作"要开抽屉"。
    static let sidebarEdgeWidth: CGFloat = 20
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
    /// 用 interactiveSpring 而不是普通 spring:侧栏是手势跟手的(sidebarDragOffset
    /// 逐帧 1:1 跟手,松手才 withAnimation 归位),普通 spring 在松手瞬间是从零速度
    /// 起跳的,和手指刚甩出去的速度对不上,过渡处会有一下不连贯的"顿挫";
    /// interactiveSpring 的 blendDuration 把这次归位动画和手势的末速度做平滑衔接,
    /// 松手那一下才不会有速度断层。点击(汉堡按钮/点遮罩关闭)触发时没有末速度可
    /// 衔接,行为退化成普通 spring,不受影响。
    static let lodoSidebar = Animation.interactiveSpring(
        response: 0.35, dampingFraction: 0.86, blendDuration: 0.15)
    /// 输入框内控件切换(麦克风⇄发送)、搜索框展开收起等轻量场景。
    static let lodoQuickFade = Animation.easeInOut(duration: 0.2)

    /// 遵守"减弱动态效果":开启时退化成一个几乎瞬时但仍然平滑的短过渡
    /// (不是直接去掉动画——纯状态硬切在有过渡的界面里反而更突兀、更容易让人
    /// 以为卡了一下),调用方原有的 value 触发逻辑不用改。
    static func lodoAware(_ animation: Animation) -> Animation {
        DesignMetrics.reduceMotionEnabled ? .linear(duration: 0.05) : animation
    }
}
