import XCTest
@testable import LodoCore

/// AgentSkillStore 的存取/重置离线单测;每个用例前后清理覆盖文件,不污染本机状态。
final class AgentSkillStoreTests: XCTestCase {
    override func tearDown() {
        for id in AgentSkillID.allCases { AgentSkillStore.reset(id) }
        super.tearDown()
    }

    func testDefaultContentNonEmpty() {
        for id in AgentSkillID.allCases {
            XCTAssertFalse(AgentSkillStore.defaultContent(for: id)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(id) 默认内容为空")
        }
    }

    func testContentFallsBackToDefaultWhenNotCustomized() {
        for id in AgentSkillID.allCases {
            XCTAssertFalse(AgentSkillStore.isCustomized(id))
            XCTAssertEqual(AgentSkillStore.content(for: id), AgentSkillStore.defaultContent(for: id))
        }
    }

    func testSaveThenContentReadsOverride() {
        AgentSkillStore.save("自定义总则内容", for: .agent)
        XCTAssertTrue(AgentSkillStore.isCustomized(.agent))
        XCTAssertEqual(AgentSkillStore.content(for: .agent), "自定义总则内容")
        // 其他 skill 不受影响
        XCTAssertFalse(AgentSkillStore.isCustomized(.todo))
    }

    func testResetRestoresDefault() {
        AgentSkillStore.save("临时内容", for: .memory)
        AgentSkillStore.reset(.memory)
        XCTAssertFalse(AgentSkillStore.isCustomized(.memory))
        XCTAssertEqual(AgentSkillStore.content(for: .memory), AgentSkillStore.defaultContent(for: .memory))
    }

    func testSaveEmptyTextActsAsReset() {
        AgentSkillStore.save("有内容", for: .todo)
        AgentSkillStore.save("   ", for: .todo)
        XCTAssertFalse(AgentSkillStore.isCustomized(.todo))
    }
}
