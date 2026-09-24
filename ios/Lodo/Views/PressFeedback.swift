import SwiftUI

/// `.buttonStyle(.plain)` 在 SwiftUI 里是**完全没有按下反馈**的——不像 .bordered
/// 那套会自己压暗一下,plain 按钮按下去到动作生效之间屏幕上什么都不变。全 app
/// 三十处图标按钮/可点卡片都用的 plain,于是整个界面的"点了到底有没有点到"这件事
/// 一直靠动作自己的结果来告知;动作要是慢一点(AI 请求、落库)或者干脆没有可见
/// 结果,按下去就像按在一张图上。
///
/// Apple 讲流体界面时把"响应"排在第一位:反馈要在**按下**那一刻就出现,不是等
/// 抬手、更不是等动作完成。这一层就是把这件事补上,并且和 `LiquidGlass`/
/// `nagSwipeActions` 一样收进单一封装,调用处只写 `.pressable()`。
///
/// 曲线是临界阻尼(dampingFraction 1.0,不回弹):按下不是甩动手势、没有动量可
/// 继承,过冲在这里只会显得轻浮。response 取 0.18——按下反馈本身要"即刻",这个
/// 量级在感知上就是跟手的,又不至于像硬切那样闪一下。
///
/// 只做 scaleEffect + opacity 这两个合成器友好的属性,不碰布局,所以按下不会引起
/// 重排、也不会把周围的东西挤动。
struct PressableButtonStyle: ButtonStyle {
    /// 按下时缩到多小。图标按钮可以明显一点,整行/整卡的大面积元素必须克制——
    /// 一张满宽卡片缩 10% 会像整页在抖。
    let pressedScale: CGFloat
    /// 按下时的不透明度。禁用态另有系统的压暗,这里只管按下。
    let pressedOpacity: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(
                .lodoAware(.spring(response: 0.18, dampingFraction: 1)),
                value: configuration.isPressed)
    }
}

extension View {
    /// 图标按钮、胶囊、小控件:原来 `.buttonStyle(.plain)` 的位置换成这个。
    func pressable() -> some View {
        buttonStyle(PressableButtonStyle(pressedScale: 0.90, pressedOpacity: 0.65))
    }

    /// 整行、整张卡这类大面积可点元素:缩放幅度刻意比 `pressable()` 小一个量级,
    /// 只靠压暗为主——大面积元素的缩放在视觉上是按面积放大的,同样的比例看着比
    /// 小图标夸张得多。
    func pressableCard() -> some View {
        buttonStyle(PressableButtonStyle(pressedScale: 0.985, pressedOpacity: 0.75))
    }
}

extension View {
    /// 把可点范围补到 HIG 的 44pt,**不改变外观尺寸**。
    ///
    /// 用在视觉上刻意做小的图标按钮上(`visualSize` 传它当前那个 frame 的边长)。
    /// 直接把 frame 放大到 44 是不行的:AI 输入栏那五颗控件(附件/麦克风/发送/
    /// 取消录音/完成录音)彼此必须同尺寸同圆心,一起放大又会把整条输入栏顶高,
    /// 而 36pt 这个值本身是调过的(见 `AgentView.sendButton` 里为什么没用
    /// `.glassProminentButton()`)。
    ///
    /// 做法:先 `padding` 撑开、`contentShape` 把撑开后的矩形认作命中区域,再用
    /// **负 padding 把布局尺寸缩回去**——父容器量到的还是原来那么大,间距和输入栏
    /// 高度都不受影响,手指却有 44pt 可点。
    ///
    /// 相邻控件间距小于补出来的那一圈时命中区会重叠、z 序在后的赢,所以只用在
    /// 彼此隔着 Spacer/输入框的独立控件上,别拿它去补一排紧挨着的小按钮。
    func hitTarget(visualSize: CGFloat) -> some View {
        let inset = max(0, (DesignMetrics.minimumHitTarget - visualSize) / 2)
        return padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }
}
