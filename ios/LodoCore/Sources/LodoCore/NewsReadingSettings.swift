import Foundation

/// 新闻的「阅读设置」(新闻页右上角菜单 → 阅读设置;文章页的「Aa」也能打开)。
/// 三项都是本机偏好,存 UserDefaults(`AppSettings.news*Key`),**存储值别改**。
public enum NewsSummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    /// 跟随应用内语言(默认,和原来的行为一样)。
    case followApp = ""
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    /// 和文章原文同一种语言(英文文章就出英文总结)。
    case original = "original"

    public var id: String { rawValue }

    /// 选项上显示的名字。外语名字用它自己的写法,和系统语言列表一个习惯。
    public var displayName: String {
        switch self {
        case .followApp: return "跟随应用语言"
        case .chinese: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .original: return "与原文相同"
        }
    }

    /// 写进 prompt 的语言说法(总结/今日总结的 prompt 里是「用\(language)写」)。
    public func promptName(appLanguage: AppLanguage) -> String {
        switch self {
        case .followApp: return appLanguage == .en ? "英文" : "中文"
        case .chinese: return "中文"
        case .english: return "英文"
        case .japanese: return "日文"
        case .korean: return "韩文"
        case .original: return "文章原文所用的语言"
        }
    }

    public static func stored(_ raw: String?) -> NewsSummaryLanguage {
        raw.flatMap(NewsSummaryLanguage.init(rawValue:)) ?? .followApp
    }
}

/// 正文字号:五档,映射到 Dynamic Type 的相对档位(阅读页整体套一个
/// `dynamicTypeSize`),所以标题、正文、引用按同一个比例一起变,不写死磅值。
public enum NewsFontSize: Int, CaseIterable, Identifiable, Sendable {
    case small = 0, standard, large, larger, largest

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .larger: return "较大"
        case .largest: return "特大"
        }
    }

    public static func stored(_ raw: Int?) -> NewsFontSize {
        raw.flatMap(NewsFontSize.init(rawValue:)) ?? .standard
    }
}

/// 正文左右边距:三档,点数交给视图(iPad 上正文另有最大宽度)。
public enum NewsMargin: Int, CaseIterable, Identifiable, Sendable {
    case narrow = 0, standard, wide

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .narrow: return "窄"
        case .standard: return "标准"
        case .wide: return "宽"
        }
    }

    public var points: Double {
        switch self {
        case .narrow: return 12
        case .standard: return 20
        case .wide: return 36
        }
    }

    public static func stored(_ raw: Int?) -> NewsMargin {
        raw.flatMap(NewsMargin.init(rawValue:)) ?? .standard
    }
}
