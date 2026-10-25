#if os(iOS)
import UIKit
import LodoKeyboardModel

/// lodo 的强调色(跟着主 app 设置里选的那一档,扩展从 App Group 读来设给控制器)。
/// 三个槽位同主 app 的 `AccentPalette`:accent 彩色图标/光标,fill 实心按钮底,onFill 按钮上的字。
public struct KeyboardAccent: Sendable {
    public var accent: UIColor
    public var fill: UIColor
    public var onFill: UIColor

    public init(accent: UIColor, fill: UIColor, onFill: UIColor) {
        self.accent = accent; self.fill = fill; self.onFill = onFill
    }

    /// 明暗两个 0xRRGGBB 值拼成动态色。
    public static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        func rgb(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return KeyboardAppearance.dynamic(light: rgb(light), dark: rgb(dark))
    }

    /// 主 app 的默认档「赤陶」。
    public static let terracotta = KeyboardAccent(
        accent: dynamic(light: 0xC2410C, dark: 0xFF9E4D),
        fill: dynamic(light: 0xC2410C, dark: 0xFF9500),
        onFill: dynamic(light: 0xFFFFFF, dark: 0x1A1206))
}

/// 键盘的配色与字体,全收在这一处。
///
/// 背板不归我们画:根视图是 `UIInputView(inputViewStyle: .keyboard)`,系统按当前版本画键盘底
/// (iOS 26 起是系统自己的 Liquid Glass 背板),我们只画平面的键帽,不再叠一层玻璃——玻璃采样不到玻璃。
/// 键帽色值是对着 iOS 26 系统键盘估的,真机截图比对后在这里改。
enum KeyboardAppearance {
    /// 当前强调色;一个扩展进程里只有一个键盘,由 `KeyboardController.accent` 设。
    @MainActor static var accent = KeyboardAccent.terracotta

    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// 「减弱透明度」开着时键帽不透明。
    static var reducesTransparency: Bool { UIAccessibility.isReduceTransparencyEnabled }
    /// 「增强对比度」开着时键帽加描边。
    static var increasesContrast: Bool { UIAccessibility.isDarkerSystemColorsEnabled }

    static var characterKey: UIColor {
        reducesTransparency
            ? dynamic(light: .white, dark: UIColor(white: 0.42, alpha: 1))
            : dynamic(light: UIColor(white: 1, alpha: 0.92), dark: UIColor(white: 1, alpha: 0.28))
    }

    static var functionKey: UIColor {
        reducesTransparency
            ? dynamic(light: UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1), dark: UIColor(white: 0.27, alpha: 1))
            : dynamic(light: UIColor(red: 0.55, green: 0.58, blue: 0.63, alpha: 0.42), dark: UIColor(white: 1, alpha: 0.13))
    }

    /// 放大气泡永远不透明:它盖在候选栏上,透出底下的字就看不清了。
    static let calloutFill = dynamic(light: .white, dark: UIColor(white: 0.42, alpha: 1))

    /// 回车键在「搜索/发送/前往…」时是系统蓝底白字,同系统键盘。
    static let prominentKey = UIColor.systemBlue

    static let keyBorder = dynamic(light: UIColor(white: 0, alpha: 0.35), dark: UIColor(white: 1, alpha: 0.45))

    /// 旧系统(iOS 26 以前)的键帽底下有一道 1pt 阴影。
    static var drawsKeyShadow: Bool {
        if #available(iOS 26.0, *) { return false }
        return true
    }

    static func letterFont(pad: Bool) -> UIFont { .systemFont(ofSize: pad ? 24 : 23, weight: .regular) }
    static let symbolFont = UIFont.systemFont(ofSize: 22, weight: .regular)
    static let functionFont = UIFont.systemFont(ofSize: 16, weight: .regular)
    static let calloutFont = UIFont.systemFont(ofSize: 38, weight: .regular)
    static let candidateFont = UIFont.systemFont(ofSize: 19, weight: .regular)
    static let preeditFont = UIFont.systemFont(ofSize: 12, weight: .regular)
}
#endif
