import XCTest
@testable import LodoCore

/// AgentPreferences 的追加/去重/编辑离线单测;每个用例前后清空文件,不留下本机状态。
/// (与 AgentSkillStoreTests 一样直接跑真实路径下的文件,用例自己负责清理。)
final class AgentPreferencesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentPreferences.reset()
    }

    override func tearDown() {
        AgentPreferences.reset()
        super.tearDown()
    }

    func testEmptyByDefault() {
        XCTAssertNil(AgentPreferences.content)
        XCTAssertTrue(AgentPreferences.existingLines.isEmpty)
    }

    func testAppendWritesListLine() {
        AgentPreferences.append("开会默认留 60 分钟")
        XCTAssertEqual(AgentPreferences.existingLines, ["- 开会默认留 60 分钟"])
    }

    func testAppendSkipsBlank() {
        AgentPreferences.append("   ")
        XCTAssertNil(AgentPreferences.content)
    }

    /// 完全相同、以及互相包含的条目都算重复,不重复记。
    func testAppendDeduplicates() {
        AgentPreferences.append("开会默认留 60 分钟")
        AgentPreferences.append("开会默认留 60 分钟")
        AgentPreferences.append("开会默认留 60 分钟,除非另说")
        XCTAssertEqual(AgentPreferences.existingLines.count, 1)
    }

    func testAppendKeepsDistinctPreferences() {
        AgentPreferences.append("开会默认留 60 分钟")
        AgentPreferences.append("说话简短点")
        XCTAssertEqual(AgentPreferences.existingLines.count, 2)
    }

    /// 手写保存时标题行不算条目,但仍留在文件里。
    func testSaveThenReadBackIgnoresHeadingInLines() {
        AgentPreferences.save("# 用户偏好\n- 我一般 9 点上班\n")
        XCTAssertEqual(AgentPreferences.existingLines, ["- 我一般 9 点上班"])
        XCTAssertEqual(AgentPreferences.content?.contains("# 用户偏好"), true)
    }

    func testSaveEmptyActsAsReset() {
        AgentPreferences.append("开会默认留 60 分钟")
        AgentPreferences.save("  ")
        XCTAssertNil(AgentPreferences.content)
    }
}
