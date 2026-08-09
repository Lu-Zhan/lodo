import Foundation

/// App 图标配色(莫兰迪色系),用户在设置里手动选,默认白色。白色对应主图标
/// (Assets.xcassets 里的 "AppIcon"),其余四色是备用图标集,通过
/// UIApplication.setAlternateIconName(_:) 切换(仅 iOS,macOS 无对应 API,
/// 调用点在 SettingsView 里 #if os(iOS) 门控)。
public enum AppIconStyle: String, CaseIterable, Sendable {
    case white, pink, green, brown, blue, black

    public var displayName: String {
        switch self {
        case .white: return "白色"
        case .pink: return "粉色"
        case .green: return "绿色"
        case .brown: return "棕色"
        case .blue: return "蓝色"
        case .black: return "黑色"
        }
    }

    /// 传给 setAlternateIconName 的备用图标集名字;白色是主图标,传 nil 代表"恢复默认"。
    public var alternateIconName: String? {
        switch self {
        case .white: return nil
        case .pink: return "AppIcon-Pink"
        case .green: return "AppIcon-Green"
        case .brown: return "AppIcon-Brown"
        case .blue: return "AppIcon-Blue"
        case .black: return "AppIcon-Black"
        }
    }

    /// 设置页预览用的普通 Image 资源名(与 alternateIconName 对应的 appiconset 内容一致,
    /// 但 appiconset 不能直接被 Image(_:) 加载,所以另存了一份同图的 imageset)。
    public var previewImageName: String {
        switch self {
        case .white: return "IconPreviewWhite"
        case .pink: return "IconPreviewPink"
        case .green: return "IconPreviewGreen"
        case .brown: return "IconPreviewBrown"
        case .blue: return "IconPreviewBlue"
        case .black: return "IconPreviewBlack"
        }
    }
}
