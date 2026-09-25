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
}
