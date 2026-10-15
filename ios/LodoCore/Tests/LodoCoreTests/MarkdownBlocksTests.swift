import XCTest
@testable import LodoCore

final class MarkdownBlocksTests: XCTestCase {
    func testPlainTextIsOneParagraphWithLineBreaks() {
        let text = "明天下午三点开会。\n记得带电脑。"
        XCTAssertEqual(MarkdownParser.parse(text), [.paragraph(text)])
        XCTAssertFalse(MarkdownParser.hasBlockSyntax(text))
    }

    func testHeadingsListsAndParagraphs() {
        let text = """
        ## 今天的安排
        先处理这几件:
        - **周报**
        - 回邮件
          记得抄送老板
        1. 第一步
        2) 第二步
        """
        XCTAssertEqual(MarkdownParser.parse(text), [
            .heading(level: 2, text: "今天的安排"),
            .paragraph("先处理这几件:"),
            .list([
                MarkdownListItem(indent: 0, ordinal: nil, text: "**周报**"),
                MarkdownListItem(indent: 0, ordinal: nil, text: "回邮件\n记得抄送老板"),
                MarkdownListItem(indent: 0, ordinal: "1.", text: "第一步"),
                MarkdownListItem(indent: 0, ordinal: "2)", text: "第二步"),
            ]),
        ])
    }

    func testBoldAtLineStartIsNotAList() {
        XCTAssertEqual(MarkdownParser.parse("**注意**:别忘了"), [.paragraph("**注意**:别忘了")])
        XCTAssertEqual(MarkdownParser.parse("#话题 不是标题"), [.paragraph("#话题 不是标题")])
        XCTAssertEqual(MarkdownParser.parse("2026年10月15日"), [.paragraph("2026年10月15日")])
    }

    func testNestedListIndent() {
        let blocks = MarkdownParser.parse("- 水果\n  - 苹果\n    - 红富士")
        XCTAssertEqual(blocks, [.list([
            MarkdownListItem(indent: 0, ordinal: nil, text: "水果"),
            MarkdownListItem(indent: 1, ordinal: nil, text: "苹果"),
            MarkdownListItem(indent: 2, ordinal: nil, text: "红富士"),
        ])])
    }

    func testCodeQuoteRule() {
        let text = """
        > 引用一句
        > 第二行
        ---
        ```swift
        let a = 1
        - 不是列表
        ```
        结尾
        """
        XCTAssertEqual(MarkdownParser.parse(text), [
            .quote("引用一句\n第二行"),
            .rule,
            .code(language: "swift", text: "let a = 1\n- 不是列表"),
            .paragraph("结尾"),
        ])
    }

    func testUnclosedCodeFenceRunsToEnd() {
        XCTAssertEqual(MarkdownParser.parse("```\nabc"), [.code(language: "", text: "abc")])
    }

    func testTable() {
        let text = """
        | 城市 | 天数 |
        |:---|---:|
        | 东京 | 4 |
        | 京都 | 3 | 多余 |
        | 大阪 |
        """
        XCTAssertEqual(MarkdownParser.parse(text), [
            .table(header: ["城市", "天数"], rows: [["东京", "4"], ["京都", "3"], ["大阪", ""]]),
        ])
    }

    func testPipeWithoutSeparatorIsParagraph() {
        XCTAssertEqual(MarkdownParser.parse("A | B"), [.paragraph("A | B")])
    }
}
