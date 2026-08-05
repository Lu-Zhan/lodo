import Foundation

/// 应用内语言开关(独立于系统语言,用户在设置里手动选)。View 层字面量 Text()
/// 走 SwiftUI 的 .environment(\.locale)(见 app 层 LodoApp.swift);非 View 上下文
/// (错误文案、通知模板)显式传这个值,不依赖环境隐式传播——见 LocalizedStrings。
public enum AppLanguage: String, CaseIterable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var locale: Locale { Locale(identifier: rawValue) }

    /// 语言选择器自身的展示名(不经过生成表,这两个词本身就是"人类可读语言名")。
    public var displayName: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "English"
        }
    }
}
