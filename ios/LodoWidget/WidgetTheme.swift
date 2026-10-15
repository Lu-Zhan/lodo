import SwiftUI
import UIKit

/// app 写进 App Group 的强调色(字段与 app 侧 `WidgetBridge.Theme` 一致)。小组件读不到
/// app 的设置,只能按这两个色值自己拼出明暗两套;没写过时用默认的赤陶。
struct WidgetTheme: Codable {
    let accentLight: UInt32
    let accentDark: UInt32

    static let fallback = WidgetTheme(accentLight: 0xC2410C, accentDark: 0xFF9E4D)

    static func load() -> WidgetTheme {
        guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lodo.app")?
                .appending(path: "widget-theme.json"),
              let data = try? Data(contentsOf: url),
              let theme = try? JSONDecoder().decode(WidgetTheme.self, from: data) else { return fallback }
        return theme
    }

    var accent: Color {
        Color(uiColor: UIColor { trait in
            Self.color(trait.userInterfaceStyle == .dark ? accentDark : accentLight)
        })
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// 桌面小组件统一的白底(深色模式下是系统背景的黑)。锁屏那几种仍是 `.clear`。
    func homeWidgetBackground() -> some View {
        containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }
}
