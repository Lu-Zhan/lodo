import SwiftUI
import LodoCore

/// AI 回复的 Markdown 渲染:块级结构由 `MarkdownParser`(LodoCore,有单测)切好,
/// 行内(粗体/斜体/行内代码/链接)交给 `AttributedString` 的 inlineOnly 模式。
/// 全是系统控件和系统形状拼的(Text / Grid / Divider / RoundedRectangle),不自绘。
/// 没有 Markdown 的一段话解析出来就是一个段落,显示和原来的纯文字一样。
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.ordinal ?? (item.indent == 0 ? "•" : "◦"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        inline(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                inline(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(10)
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider()
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(.subheadline)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .body.weight(.semibold)
        }
    }

    /// 行内语法;解析失败原样显示,不丢字。
    private func inline(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(raw)
    }
}
