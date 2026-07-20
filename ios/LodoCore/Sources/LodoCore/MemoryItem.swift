import Foundation
import SwiftData

/// 记忆条目的内容类型;ppt/docx 等不解析内容的文件统一归 file。
public enum MemoryKind: String {
    case text
    case link
    case pdf
    case image
    case file

    /// 列表卡片/详情页的 SF Symbol。
    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    public var label: String {
        switch self {
        case .text: return "文字"
        case .link: return "链接"
        case .pdf: return "PDF"
        case .image: return "图片"
        case .file: return "文件"
        }
    }
}

/// 记忆条目的整理状态:AI 整理中 / 已整理 / 整理失败(可重试,原文已保留)。
public enum MemoryStatus: String {
    case processing
    case ready
    case failed
}

/// "AI 收藏/记忆"条目:收藏的原文(提取文本 + 可选原始文件)加上 AI 整理出的
/// 标题/摘要/标签。与 TaskItem 一样放 LodoCore 统一模型定义;
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
/// 原始文件存 App Group 的 Memory/ 目录、条目只记相对路径——文件本身不进
/// CloudKit(避免吃 iCloud 配额),其他设备上条目可见可搜,原文件缺失时给占位说明。
@Model
public final class MemoryItem {
    public var uuid: UUID = UUID()
    public var kindRaw: String = "text"
    public var title: String = ""
    public var summary: String = ""
    public var tags: [String] = []
    /// 端上提取的文本(已截断),本地搜索与"问 AI"的语料。
    public var sourceText: String = ""
    /// kind == link 时的原始 URL。
    public var urlString: String?
    public var originalFileName: String?
    /// App Group 容器下的相对路径(如 "Memory/<uuid>.pdf");纯文字/链接为 nil。
    public var relativeFilePath: String?
    public var statusRaw: String = "ready"
    public var createdAt: Date = Date.now

    public init(
        kind: MemoryKind,
        title: String = "",
        summary: String = "",
        tags: [String] = [],
        sourceText: String = "",
        urlString: String? = nil,
        originalFileName: String? = nil,
        relativeFilePath: String? = nil,
        status: MemoryStatus = .processing
    ) {
        self.uuid = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.summary = summary
        self.tags = tags
        self.sourceText = sourceText
        self.urlString = urlString
        self.originalFileName = originalFileName
        self.relativeFilePath = relativeFilePath
        self.statusRaw = status.rawValue
        self.createdAt = Date()
    }

    public var kind: MemoryKind { MemoryKind(rawValue: kindRaw) ?? .text }
    public var status: MemoryStatus { MemoryStatus(rawValue: statusRaw) ?? .ready }

    /// 本地即时过滤的匹配:标题/摘要/标签/原文任一命中即可。
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if title.localizedStandardContains(query) { return true }
        if summary.localizedStandardContains(query) { return true }
        if tags.contains(where: { $0.localizedStandardContains(query) }) { return true }
        return sourceText.localizedStandardContains(query)
    }
}
