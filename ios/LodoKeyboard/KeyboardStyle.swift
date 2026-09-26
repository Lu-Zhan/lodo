import SwiftUI
import UIKit

/// 键盘扩展自己的一套配色与玻璃封装。扩展是独立 target,用不到主 app 的
/// `LiquidGlass.swift` / `LodoPalette.swift`,这里按同样的口径各留一份最小实现。
enum KeyboardColors {
    /// 与主 app 默认强调色「赤陶橙」同值(明暗双值,理由见 LodoPalette)。
    static let accent = dynamic(light: 0xC2410C, dark: 0xFF9E4D)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x1A1206)

    /// 系统键盘的字母键 / 功能键 / 按键底边阴影(明暗两套取自原生键盘)。
    static let letterKey = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.30) : .white
    })
    static let functionKey = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.14)
            : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
    })
    static let keyShadow = Color(uiColor: UIColor { trait in
        UIColor(white: 0, alpha: trait.userInterfaceStyle == .dark ? 0.45 : 0.30)
    })

    /// iOS 26 起系统键盘的键帽更圆。
    static var keyRadius: CGFloat {
        if #available(iOS 26.0, *) { return 8.5 }
        return 5
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    /// Liquid Glass(iOS 26+),旧系统与「减弱透明度」退回材质/不透明底。
    func keyboardGlass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(KeyboardGlassModifier(shape: shape, interactive: interactive, tint: tint))
    }
}

private struct KeyboardGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? Color(uiColor: .secondarySystemBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background {
                if let tint { shape.fill(tint) } else { shape.fill(.regularMaterial) }
            }
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// 相邻的几块玻璃合进一个容器:玻璃采样不到玻璃,各自为政时亮度折射对不上。
struct KeyboardGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// 扩展里没有主 app 的 `.pressable()`,按下反馈用同样的临界阻尼缩放。
struct KeyboardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}
