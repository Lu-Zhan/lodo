import Foundation

/// AI 回复的 Markdown 分块(标题/列表/引用/代码块/分隔线/表格/段落)。行内语法(粗体、
/// 斜体、行内代码、链接)不在这里处理,交给 `AttributedString(markdown:)` 的
/// inlineOnly 模式;这里只负责系统那条 API 不管的块级结构(它的 full 模式会把换行
/// 吞掉、列表符号丢掉,渲染不出来)。
///
/// 容错优先:模型输出不保证是合法 Markdown,认不出的一律当段落原样显示,不丢字。
/// 普通的一段话(没有任何 Markdown)解析出来就是一个段落,显示和原来一样。
public enum MarkdownBlock: Equatable, Sendable {
    /// level 1...6。
    case heading(level: Int, text: String)
    /// 段落,行内换行保留(中文回复里的换行就是换行)。
    case paragraph(String)
    case list([MarkdownListItem])
    case quote(String)
    case code(language: String, text: String)
    case rule
    case table(header: [String], rows: [[String]])
}

public struct MarkdownListItem: Equatable, Sendable {
    /// 缩进层级(每 2 个空格一层,tab 算一层),最多 3 层。
    public var indent: Int
    /// 有序列表写的那个序号("1."),无序为 nil。
    public var ordinal: String?
    public var text: String

    public init(indent: Int, ordinal: String?, text: String) {
        self.indent = indent
        self.ordinal = ordinal
        self.text = text
    }
}

public enum MarkdownParser {
    public static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [MarkdownListItem] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(listItems))
                listItems = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码块:``` 开头,到下一个 ``` 为止(没闭合就到结尾)。
            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            // 表格:这一行带 |,下一行是 |---|---| 分隔行。
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushAll()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var values = cells(row)
                    // 列数对齐表头:多的截掉、少的补空,Grid 才排得齐。
                    if values.count > header.count { values = Array(values.prefix(header.count)) }
                    while values.count < header.count { values.append("") }
                    rows.append(values)
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var text = String(trimmed.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                quote.append(text)
                index += 1
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                listItems.append(item)
                index += 1
                continue
            }

            // 列表项下面缩进的续行:接到上一项里。
            if !listItems.isEmpty, line.first == " " || line.first == "\t" {
                listItems[listItems.count - 1].text += "\n" + trimmed
                index += 1
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    /// 文本里有没有块级 Markdown(标题/列表/引用/代码块/分隔线/表格)。只有段落时
    /// 调用方可以照原来的单个 Text 显示。
    public static func hasBlockSyntax(_ raw: String) -> Bool {
        parse(raw).contains { block in
            if case .paragraph = block { return false }
            return true
        }
    }

    // MARK: - 行判断

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // "#话题" 这种不带空格的不算标题。
        guard let first = rest.first, first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // 收尾的 ### 去掉。
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ trimmed: String) -> Bool {
        guard trimmed.contains("-") else { return false }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let core = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ row: String) -> [String] {
        var text = row
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        var spaces = 0
        for char in line {
            if char == " " { spaces += 1 } else if char == "\t" { spaces += 2 } else { break }
        }
        let indent = min(spaces / 2, 3)
        let body = line.drop { $0 == " " || $0 == "\t" }

        // 无序:- * + 后面跟空格(**粗体** 开头的不是列表)。
        if let marker = body.first, "-*+•".contains(marker) {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            return MarkdownListItem(indent: indent, ordinal: nil,
                                    text: rest.trimmingCharacters(in: .whitespaces))
        }
        // 有序:数字 + . 或 ) + 空格。
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let punct = afterDigits.first, punct == "." || punct == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return MarkdownListItem(indent: indent, ordinal: "\(digits)\(punct)",
                                text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
