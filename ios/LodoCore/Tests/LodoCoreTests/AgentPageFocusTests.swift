import XCTest
@testable import LodoCore

final class AgentPageFocusTests: XCTestCase {
    func testEveryPageBlockNamesPageAndKeepsOtherDomainsOpen() {
        for focus in AgentPageFocus.allCases {
            let block = focus.promptBlock
            XCTAssertTrue(block.contains("「\(focus.pageName)」"))
            XCTAssertTrue(block.contains("用户明确提到其他领域"))
        }
    }

    func testTravelBlockPointsAtReadTrip() {
        XCTAssertTrue(AgentPageFocus.travel.promptBlock.contains("read_trip"))
    }

    /// 带具体对象(旅行详情页)时,prompt 里要点名那次旅行,并且仍然留着
    /// "别的领域照常处理"这条后路。
    func testSubjectFocusNamesTheTripAndStaysOpen() {
        let focus = AgentFocus.travel(trip: "东京四日")
        XCTAssertEqual(focus.subject, "东京四日")
        XCTAssertTrue(focus.promptBlock.contains("「东京四日」"))
        XCTAssertTrue(focus.promptBlock.contains("read_trip"))
        XCTAssertTrue(focus.promptBlock.contains("别的领域"))
    }

    /// 名字是空白时退回整页那段,不给 AI 一个空的「」。
    func testBlankSubjectFallsBackToPageBlock() {
        XCTAssertNil(AgentFocus.travel(trip: "   ").subject)
        XCTAssertEqual(AgentFocus.travel(trip: "   ").promptBlock,
                       AgentPageFocus.travel.promptBlock)
    }
}
