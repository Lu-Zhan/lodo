import XCTest
@testable import LodoCore

/// skill 分享文件(frontmatter + 正文)的解析/渲染离线单测。
final class AgentSkillFileTests: XCTestCase {
    private let sample = """
    ---
    name: 日料点菜助手
    description: 用户在餐厅问点菜时使用
    group: 自定义
    version: 2
    ---
    先问几位用餐,再按人均推荐。
    """

    func testParseReadsFields() throws {
        let file = try AgentSkillFile.parse(sample).get()
        XCTAssertEqual(file.name, "日料点菜助手")
        XCTAssertEqual(file.description, "用户在餐厅问点菜时使用")
        XCTAssertEqual(file.group, "自定义")
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(file.body, "先问几位用餐,再按人均推荐。")
    }

    func testRenderRoundTrip() throws {
        let file = try AgentSkillFile.parse(sample).get()
        XCTAssertEqual(try AgentSkillFile.parse(file.render()).get(), file)
    }

    func testQuotedValuesAndCRLFAndBOM() throws {
        let text = "\u{FEFF}---\r\nname: \"带引号\"\r\ndescription: '说明'\r\nunknown: x\r\n---\r\n正文\r\n"
        let file = try AgentSkillFile.parse(text).get()
        XCTAssertEqual(file.name, "带引号")
        XCTAssertEqual(file.description, "说明")
        XCTAssertEqual(file.body, "正文")
    }

    func testRejectsMissingParts() {
        XCTAssertEqual(AgentSkillFile.parse("没有头信息").failureError, .missingFrontmatter)
        XCTAssertEqual(AgentSkillFile.parse("---\ndescription: d\n---\nb").failureError, .missingName)
        XCTAssertEqual(AgentSkillFile.parse("---\nname: n\n---\nb").failureError, .missingDescription)
        XCTAssertEqual(AgentSkillFile.parse("---\nname: n\ndescription: d\n---\n  \n").failureError, .emptyBody)
        // 头信息没有收尾的 ---
        XCTAssertEqual(AgentSkillFile.parse("---\nname: n\ndescription: d\n正文").failureError, .missingFrontmatter)
    }

    func testRejectsOverlongFields() {
        let body = String(repeating: "长", count: AgentSkillFile.maxBodyLength + 1)
        XCTAssertEqual(AgentSkillFile.parse("---\nname: n\ndescription: d\n---\n\(body)").failureError, .bodyTooLong)
        let name = String(repeating: "名", count: AgentSkillFile.maxNameLength + 1)
        XCTAssertEqual(AgentSkillFile.parse("---\nname: \(name)\ndescription: d\n---\nb").failureError, .nameTooLong)
        let desc = String(repeating: "述", count: AgentSkillFile.maxDescriptionLength + 1)
        XCTAssertEqual(AgentSkillFile.parse("---\nname: n\ndescription: \(desc)\n---\nb").failureError, .descriptionTooLong)
    }

    func testRenderFlattensNewlinesInHeader() throws {
        let file = AgentSkillFile(name: "a\nb", description: "c\nd", body: "x")
        let parsed = try AgentSkillFile.parse(file.render()).get()
        XCTAssertEqual(parsed.name, "a b")
        XCTAssertEqual(parsed.description, "c d")
    }
}

private extension Result {
    var failureError: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
