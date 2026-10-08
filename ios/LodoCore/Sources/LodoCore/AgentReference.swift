import Foundation

/// AI 对话「+」菜单里能引用的 app 内条目种类。和照片/文件/记忆不同,这些条目
/// 本来就在库里,引用时不新建记忆,只把它当前的内容整理成一段文字随这条消息发出,
/// 气泡上留一枚标签(`AgentReference`)。
///
/// **rawValue 是持久化字符串**(存在 `AgentMessage.referencesData` 里),别改。
public enum AgentReferenceKind: String, Codable, CaseIterable, Sendable {
    case task
    case countdown
    case trip
    /// 资产台账里的资产/负债(打「资产」标签的记忆条目)。
    case asset
    /// 资产页的收入 / 固定支出 / 信用卡(`FinanceEntry`)。
    case finance
    case contact
    case menu
    case news

    /// 发给模型的那段文字的抬头用的种类名。是喂给模型的格式,不随应用语言变。
    public var promptLabel: String {
        switch self {
        case .task: return "任务"
        case .countdown: return "倒数日"
        case .trip: return "旅行"
        case .asset: return "资产"
        case .finance: return "收支"
        case .contact: return "人脉"
        case .menu: return "菜单"
        case .news: return "新闻"
        }
    }

    public var symbol: String {
        switch self {
        case .task: return "checklist"
        case .countdown: return "hourglass"
        case .trip: return "airplane"
        case .asset: return "creditcard"
        case .finance: return "banknote"
        case .contact: return "person.crop.circle"
        case .menu: return "fork.knife"
        case .news: return "newspaper"
        }
    }
}

/// 一条消息引用的 app 内条目。存标题快照而不是只存 uuid:条目后来被删了,
/// 气泡上照样知道当时引用的是什么(同 `quotedContent` 存快照的理由)。
public struct AgentReference: Codable, Hashable, Sendable {
    public var kind: AgentReferenceKind
    public var id: UUID
    public var title: String

    public init(kind: AgentReferenceKind, id: UUID, title: String) {
        self.kind = kind
        self.id = id
        self.title = title
    }

    /// 随消息发给模型的那一段:抬头写明种类和标题,带上 id(要改这一条时
    /// 模型能原样引用,id 校验本来就认 `[id:…]` 外壳),下面是条目内容。
    public func promptBlock(body: String) -> String {
        let header = "[引用 · \(kind.promptLabel):\(title)] [id:\(id.uuidString)]"
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? header : header + "\n" + trimmed
    }

    public static func encode(_ references: [AgentReference]) -> Data? {
        references.isEmpty ? nil : try? JSONEncoder().encode(references)
    }

    /// 解不开(或种类是将来版本新加的、这里认不出)时整份当作没有,不让气泡崩。
    public static func decode(_ data: Data?) -> [AgentReference] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([AgentReference].self, from: data)) ?? []
    }
}
