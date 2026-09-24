import SwiftUI
import LodoCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 动态色基建

extension Color {
    /// 按明暗两套十六进制值造一个动态颜色。**强调色和状态色一律走这个,不要直接
    /// 写 `Color(red:green:blue:)`**:同一个色值不可能在白底和近黑底上都合格
    /// ——实测赤陶 #C2410C 在白底上对比度 5.18(过 AA),同一个值在 #1C1C1E 上
    /// 只有 3.29(只够图形);反过来系统橙 #FF9500 暗色下 7.74 很好,白底却只有
    /// 2.20,彩色小字和细图标会发虚。所以每个语义色都必须是明暗双值。
    static func lodoDynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(lodoHex: dark) : UIColor(lodoHex: light)
        })
        #elseif os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(lodoHex: dark) : NSColor(lodoHex: light)
        })
        #else
        return Color(lodoHex: light)
        #endif
    }

    init(lodoHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(lodoHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
#elseif os(macOS)
private extension NSColor {
    convenience init(lodoHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
#endif

// MARK: - 强调色预设

/// 可在设置里切换的强调色。**每一档的每个用法都核过 WCAG AA**(浅色前景 ≥4.5、
/// 填充上的文字 ≥4.5、暗色前景 ≥4.5、暗色填充块对背景 ≥3.0),换预设不会换出
/// 一个读不清的界面。
///
/// 三个槽位而不是一个"主题色":
/// - `accent`   彩色**文字/图标/细线/选中态**。要压得住浅背景,所以浅色模式取深一档。
/// - `fill`     **大块填充**(FAB、发送键)。暗色模式刻意比 accent 更亮——暗界面上
///              的主操作要发光,而不是压成一块深色。
/// - `onFill`   填充上那层文字/图标的颜色。浅色一律白;**暗色是近黑**,因为暗色的
///              填充是亮色,白字放上去只有 3.38 读不清(这也是为什么不能只存一个
///              "主题色"就完事)。
enum AccentPalette: String, CaseIterable, Identifiable {
    case terracotta, blue, indigo, green, rose, graphite

    var id: String { rawValue }

    /// 当前选择;存的 rawValue 认不出来时回落到默认的赤陶。
    /// 视图侧别直接调这个取色渲染——用 `@AppStorage(AppSettings.accentPaletteKey)`
    /// 绑同一个键才会在用户改设置时重建(理由同 `accessibilityReduceMotion` 那条)。
    /// 这里是给非视图路径和默认值用的。
    static var current: AccentPalette {
        AccentPalette(rawValue: AppSettings.accentPalette) ?? .terracotta
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .terracotta: "赤陶橙"
        case .blue: "靛蓝"
        case .indigo: "靛紫"
        case .green: "松绿"
        case .rose: "玫红"
        case .graphite: "石墨"
        }
    }

    /// 彩色文字/图标/选中态。
    var accent: Color {
        switch self {
        case .terracotta: .lodoDynamic(light: 0xC2410C, dark: 0xFF9E4D)
        case .blue: .lodoDynamic(light: 0x0A58CA, dark: 0x7FB3FF)
        case .indigo: .lodoDynamic(light: 0x4338CA, dark: 0xA5B4FC)
        case .green: .lodoDynamic(light: 0x13703A, dark: 0x4ADE80)
        case .rose: .lodoDynamic(light: 0xBE123C, dark: 0xFB7185)
        case .graphite: .lodoDynamic(light: 0x3F3F46, dark: 0xD4D4D8)
        }
    }

    /// 大块填充(主操作按钮)。
    var fill: Color {
        switch self {
        case .terracotta: .lodoDynamic(light: 0xC2410C, dark: 0xFF9500)
        case .blue: .lodoDynamic(light: 0x0A58CA, dark: 0x4DA3FF)
        case .indigo: .lodoDynamic(light: 0x4338CA, dark: 0x8B95F8)
        case .green: .lodoDynamic(light: 0x13703A, dark: 0x34D373)
        case .rose: .lodoDynamic(light: 0xBE123C, dark: 0xF65C74)
        case .graphite: .lodoDynamic(light: 0x3F3F46, dark: 0xC9C9CF)
        }
    }

    /// 填充上的文字/图标色。
    var onFill: Color {
        switch self {
        case .terracotta: .lodoDynamic(light: 0xFFFFFF, dark: 0x1A1206)
        case .blue: .lodoDynamic(light: 0xFFFFFF, dark: 0x05183A)
        case .indigo: .lodoDynamic(light: 0xFFFFFF, dark: 0x11103A)
        case .green: .lodoDynamic(light: 0xFFFFFF, dark: 0x04210F)
        case .rose: .lodoDynamic(light: 0xFFFFFF, dark: 0x2B0511)
        case .graphite: .lodoDynamic(light: 0xFFFFFF, dark: 0x1A1A1D)
        }
    }
}

// MARK: - 下发

private struct LodoAccentKey: EnvironmentKey {
    static let defaultValue = AccentPalette.terracotta
}

extension EnvironmentValues {
    /// 当前强调色预设。**需要显式写出强调色的地方读这个,不要用 `Color.accentColor`**
    /// ——后者取的是资源目录里的 AccentColor(这个 app 压根没定义,所以是系统蓝),
    /// 它**不跟随 `.tint()`**,用户在设置里换了色那些地方也不会变。
    /// `.tint()` 能覆盖到的系统控件不用管,继承即可;这个 key 是给那些必须自己
    /// 指定颜色的地方用的(滑动操作的 tint、胶囊底色等)。
    var lodoAccent: AccentPalette {
        get { self[LodoAccentKey.self] }
        set { self[LodoAccentKey.self] = newValue }
    }
}

// MARK: - 语义状态色

/// 状态色和强调色**分开**:强调色跟着用户选,状态色固定。橙原本兼着"品牌"和
/// "该注意了"两个身份(逾期/航班延误/稍等/价格都用 `.orange`),强调色改成橙之后
/// 这些信号会被品牌色淹没,所以这一批统一重映射——橙 = 品牌,红 = 需要注意,
/// 灰 = 中性推迟,价格这类纯数据不上色。
enum LodoColor {
    /// 红:需要注意或出了问题——逾期、航班延误、通知权限被关、通知超上限、
    /// 各处错误文案、删除操作。
    ///
    /// **不用 `Color.red`**:系统红 #FF3B30 在分组背景上对比度只有 3.14,
    /// 当正文用不合格(这个 app 的错误提示基本都是 footnote 小字,更吃亏)。
    /// 这里浅色取深一档的 #C9252D(4.91 过 AA),暗色回到亮红保持可读。
    static let critical = Color.lodoDynamic(light: 0xC9252D, dark: 0xFF6961)

    /// 中性灰:稍等、忽略、移出行程这类"往后挪/挪走但没删"的操作。
    /// 它们既不是警示也不是主操作,原来混用 `.orange`/`.gray`——橙改成品牌色
    /// 之后必须让出来,否则"稍等"和"逾期"会是同一个颜色。
    static let neutralAction = Color.lodoDynamic(light: 0x6B6B70, dark: 0x9A9AA0)

    /// 更深一档的中性:忽略。和 `neutralAction`(稍等)彼此对比度 1.71,
    /// 并排在同一排滑动操作里能分出先后——忽略比稍等更"沉下去"。
    /// 两者白字对比度分别是 9.08 / 5.30,都过 AA。
    static let muted = Color.lodoDynamic(light: 0x48484E, dark: 0xC4C4C9)

    /// 绿:完成、正向趋势。
    static let positive = Color.lodoDynamic(light: 0x13703A, dark: 0x4ADE80)
}
