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
    /// AI 助手输入栏那块玻璃的圆角。取 `AgentView.composerControlSize` 的一半:
    /// 单行时正好是个胶囊,和左边 + 号那颗玻璃圆、右边发送那颗实心圆同高同弧;
    /// 文本多行长高时圆角不跟着变,上下两端仍是半圆。
    /// (原来 26 是给"文本框 + 控件行"那张合并卡片用的,单行胶囊套 26 会被夹掉。)
    static let composerRadius: CGFloat = 18
    /// 应用导航侧栏(窄屏抽屉 / 宽屏常驻列)的固定宽度。
    static let sidebarWidth: CGFloat = 300
    /// HIG 规定的最小可点尺寸。app 里有几处图标按钮的**视觉**尺寸刻意小于它
    /// (AI 输入栏那五颗定在 36pt,彼此必须同尺寸同圆心,见
    /// `AgentView.composerControlSize`),这些地方放大的是热区不是外观——见
    /// `View.hitTarget(visualSize:)`。
    static let minimumHitTarget: CGFloat = 44

    #if DEBUG
    /// 截图验证用:模拟器上 `simctl spawn … defaults write com.apple.Accessibility
    /// ReduceTransparencyEnabled -bool true` 写进去的值**传不到 app**(实测
    /// `@Environment(\.accessibilityReduceTransparency)` 和 `UIAccessibility` 都读不到,
    /// 重启模拟器也一样),而那两个辅助功能 Environment 值是只读的(`KeyPath` 不是
    /// `WritableKeyPath`),没法在 app 根上直接顶成 true。于是在两个材质入口
    /// (`panelBackground`、`GlassBackground`)各认一个 DEBUG flag,把"减弱透明度"
    /// 这条降级路径在模拟器上做成可验证的。
    ///
    /// 这里静态读没有反应式问题——启动参数在一次运行里不会变。真实开关仍然只走
    /// Environment,这个 flag 只做"额外强制开启",不会削弱它。
    static let demoReduceTransparency =
        ProcessInfo.processInfo.arguments.contains("--demo-reduce-transparency")
    #endif
    /// 侧栏展开时被推移缩小的主内容圆角——刻意贴近真机屏幕圆角(而不是
    /// cardRadius 那种小圆角),让被推开的内容看起来像一整块"缩小的设备屏幕"。
    static let deviceCornerRadius: CGFloat = 44

    /// 侧栏面板的底色。刻意和三个页面的 List 分组底色取同一个值——抽屉推开时
    /// 面板和被推开的那张卡因此是同色的,只靠投影分层(面板原来是纯白,推开时
    /// 白/灰并排会看到一条明显的界)。没有跨平台的语义 ShapeStyle 能拿到"分组底"
    /// 这个颜色,只能按平台取系统色。
    /// **夜间仍用材质**:近黑背景上投影几乎看不见,面板再跟着变成同一个近黑色就
    /// 和被推开的那张卡糊成一片、分不出边界了——那种情况下"同色 + 投影"这套分层
    /// 本身失效,只能靠材质那点亮度差顶上。
    ///
    /// `reduceTransparency` 是系统的「减弱透明度」辅助功能开关(调用方从
    /// `\.accessibilityReduceTransparency` 读,别在这里静态读——静态读不会让视图
    /// 在用户运行中改设置时重建)。开启时夜间那层材质换成**不透明**的
    /// secondarySystemGroupedBackground:它比夜间的 systemGroupedBackground(近黑)
    /// 亮一档,正好顶替材质原本提供的那点亮度差,分层不塌,但不再有半透明。
    static func panelBackground(_ scheme: ColorScheme,
                                reduceTransparency: Bool = false) -> AnyShapeStyle {
        if scheme == .dark {
            guard reducesTransparency(reduceTransparency) else {
                return AnyShapeStyle(.regularMaterial)
            }
            #if os(iOS)
            return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
            #elseif os(macOS)
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            #else
            return AnyShapeStyle(.background)
            #endif
        }
        #if os(iOS)
        return AnyShapeStyle(Color(uiColor: .systemGroupedBackground))
        #elseif os(macOS)
        return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        #else
        return AnyShapeStyle(.background)
        #endif
    }

    /// 把调用方从 Environment 读到的「减弱透明度」和 DEBUG 截图 flag 合成一个判断。
    /// Release 构建里就是原值,没有额外分支。
    static func reducesTransparency(_ fromEnvironment: Bool) -> Bool {
        #if DEBUG
        fromEnvironment || demoReduceTransparency
        #else
        fromEnvironment
        #endif
    }

    /// 「减弱透明度」开启时用来顶替玻璃/材质的不透明面色(见 `glassBackground`)。
    /// 取 secondary 那一档而不是纯 systemBackground:这些面(AI 输入栏、悬浮条、
    /// 气泡)原本就是浮在内容之上的一层,和页面底色取同色会失去层次。
    static var opaqueSurface: AnyShapeStyle {
        #if os(iOS)
        AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        #elseif os(macOS)
        AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        #else
        AnyShapeStyle(.background)
        #endif
    }

    /// 系统"减弱动态效果"辅助功能开关。之前全仓库没有任何地方读过这个值,
    /// 所有弹簧/过渡动画不分青红皂白照放——`Animation.lodoAware(_:)` 统一
    /// 收敛在这一处判断,调用方不用各自 `#if os(iOS)` 分支。
    ///
    /// **只给 `lodoAware` 这种"动作发生那一刻求值"的地方用,别在 body 里读。**
    /// 这是个静态属性,不是 Environment:SwiftUI 不知道它变了,body 里读它的视图
    /// 在用户运行中改这项设置时不会重建,效果会一直放到下一次别的原因刷新为止。
    /// body 里要判断的一律用 `@Environment(\.accessibilityReduceMotion)`
    /// (见 `ShimmerText`、`TypewriterText`、`RecordingWaveform`、`EasterEggView`)。
    /// `withAnimation(.lodoAware(...))` 不受这条影响——它在按钮点下去那一刻才求值,
    /// 静态读到的本来就是当时的最新值。
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
