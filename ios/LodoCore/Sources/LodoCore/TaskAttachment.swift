import Foundation

/// 待办事项的记忆附件:"转为待办"时从 MemoryItem 拷贝过来的内容快照
/// (不带原始文件,只带已提取的文字/链接),独立于原记忆条目存在——
/// 原记忆条目之后被编辑或删除都不影响已经转成待办的这份内容。
/// 直接新建的待办没有附件(TaskItem.attachment 为 nil)。
public struct TaskAttachment: Equatable {
    public var kind: MemoryKind
    public var title: String
    public var summary: String
    public var text: String
    /// kind == .link 时的原始 URL。
    public var urlString: String?
    public var originalFileName: String?

    public init(
        kind: MemoryKind, title: String, summary: String, text: String,
        urlString: String? = nil, originalFileName: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.text = text
        self.urlString = urlString
        self.originalFileName = originalFileName
    }
}
