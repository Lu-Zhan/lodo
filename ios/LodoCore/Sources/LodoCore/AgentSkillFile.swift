import Foundation

/// 可分享的 skill 文件:YAML frontmatter(name/description/…)+ Markdown 正文。
/// 纯逻辑,不碰文件系统和 UI,离线单测(`AgentSkillFileTests`)。
///
///     ---
///     name: 日料点菜助手
///     description: 用户在餐厅问点菜时使用
///     group: 自定义
///     ---
///     正文…
///
/// 只认这几个键,其余键忽略(向前兼容别人写的 SKILL.md 风格文件)。
public struct AgentSkillFile: Equatable {
    /// 正文长度上限:外部 skill 是不受信文本,又会整段喂给模型,得有个上界。
    public static let maxBodyLength = 6000
    public static let maxNameLength = 40
    public static let maxDescriptionLength = 200

    public var name: String
    public var description: String
    public var group: String?
    public var version: Int?
    public var body: String

    public init(name: String, description: String, group: String? = nil,
                version: Int? = nil, body: String) {
        self.name = name
        self.description = description
        self.group = group
        self.version = version
        self.body = body
    }

    public enum ParseError: Error, Equatable {
        case missingFrontmatter
        case missingName
        case missingDescription
        case emptyBody
        case nameTooLong
        case descriptionTooLong
        case bodyTooLong

        /// 给导入页直接展示的原因。
        public var message: String {
            switch self {
            case .missingFrontmatter: return "文件开头缺少 --- 包起来的头信息(name/description)"
            case .missingName: return "头信息里缺少 name"
            case .missingDescription: return "头信息里缺少 description"
            case .emptyBody: return "正文是空的"
            case .nameTooLong: return "name 不能超过 \(AgentSkillFile.maxNameLength) 个字"
            case .descriptionTooLong: return "description 不能超过 \(AgentSkillFile.maxDescriptionLength) 个字"
            case .bodyTooLong: return "正文不能超过 \(AgentSkillFile.maxBodyLength) 个字"
            }
        }
    }

    /// 解析文件文本;不合法时返回具体原因。
    public static func parse(_ text: String) -> Result<AgentSkillFile, ParseError> {
        // 去掉 BOM 与开头空行;统一换行
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[start].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(start + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return .failure(.missingFrontmatter)
        }

        var fields: [String: String] = [:]
        for line in lines[(start + 1)..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces))
            if !key.isEmpty { fields[key] = value }
        }

        let name = fields["name"] ?? ""
        let desc = fields["description"] ?? ""
        let body = lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty { return .failure(.missingName) }
        if desc.isEmpty { return .failure(.missingDescription) }
        if body.isEmpty { return .failure(.emptyBody) }
        if name.count > maxNameLength { return .failure(.nameTooLong) }
        if desc.count > maxDescriptionLength { return .failure(.descriptionTooLong) }
        if body.count > maxBodyLength { return .failure(.bodyTooLong) }

        let group = fields["group"].flatMap { $0.isEmpty ? nil : $0 }
        return .success(AgentSkillFile(name: name, description: desc, group: group,
                                       version: fields["version"].flatMap { Int($0) },
                                       body: body))
    }

    /// 渲染成可分享的文本;`parse(render())` 往返得到等价内容。
    public func render() -> String {
        var head = ["---", "name: \(Self.singleLine(name))",
                    "description: \(Self.singleLine(description))"]
        if let group, !group.isEmpty { head.append("group: \(Self.singleLine(group))") }
        if let version { head.append("version: \(version)") }
        head.append("---")
        return head.joined(separator: "\n") + "\n" + body + "\n"
    }

    /// 头信息是逐行 `key: value`,值里的换行会破坏结构,压成一行。
    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
