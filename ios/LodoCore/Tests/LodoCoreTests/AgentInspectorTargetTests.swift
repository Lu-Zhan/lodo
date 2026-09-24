import XCTest
@testable import LodoCore

final class AgentInspectorTargetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_783_000_000)

    private func planMessage(applied: UUID? = nil, reverted: Bool? = nil) -> AgentMessage {
        var plan = TripPlanProposal(tripTitle: "东京", startDate: start,
                                    endDate: start.addingTimeInterval(86_400 * 3),
                                    items: [TripPlanItem(kind: .place, title: "浅草寺")])
        plan.appliedTripUUID = applied
        plan.reverted = reverted
        return AgentMessage(role: .assistant, kind: .tripPlan, content: "",
                            tripPlanSnapshotData: try? JSONEncoder().encode(plan))
    }

    private func editMessage(trip: UUID, reverted: Bool? = nil) -> AgentMessage {
        var record = TripEditRecord(tripUUID: trip, tripTitle: "东京", summary: "")
        record.reverted = reverted
        return AgentMessage(role: .assistant, kind: .tripEdit, content: "",
                            tripEditSnapshotData: try? JSONEncoder().encode(record))
    }

    func testUnappliedPlanPointsAtMessage() {
        let message = planMessage()
        XCTAssertEqual(AgentInspectorTarget.from(message), .tripPlan(message.uuid))
    }

    func testAppliedPlanPointsAtTrip() {
        let trip = UUID()
        XCTAssertEqual(AgentInspectorTarget.from(planMessage(applied: trip)), .trip(trip))
    }

    func testRevertedPlanFallsBackToPreview() {
        let message = planMessage(applied: UUID(), reverted: true)
        XCTAssertEqual(AgentInspectorTarget.from(message), .tripPlan(message.uuid))
    }

    func testTextMessagesHaveNoTarget() {
        let text = AgentMessage(role: .assistant, content: "你好")
        XCTAssertNil(AgentInspectorTarget.from(text))
        XCTAssertNil(AgentInspectorTarget.latest(in: [text]))
    }

    func testLatestPicksNewestAndSkipsRevertedEdit() {
        let tripA = UUID(), tripB = UUID()
        let messages = [
            planMessage(applied: tripA),
            AgentMessage(role: .user, content: "第二天改去奈良"),
            editMessage(trip: tripB),
            editMessage(trip: tripA, reverted: true),
            AgentMessage(role: .assistant, content: "好的"),
        ]
        XCTAssertEqual(AgentInspectorTarget.latest(in: messages), .trip(tripB))
    }
}
