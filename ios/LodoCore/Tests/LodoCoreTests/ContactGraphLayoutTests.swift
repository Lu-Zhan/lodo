import XCTest
@testable import LodoCore

final class ContactGraphLayoutTests: XCTestCase {
    func testZeroNodesReturnsEmpty() {
        XCTAssertEqual(
            ContactGraphLayout.circlePositions(count: 0, radius: 100, center: (0, 0)).count, 0)
    }

    func testSingleNodeSitsAtCenter() {
        let positions = ContactGraphLayout.circlePositions(count: 1, radius: 100, center: (5, 7))
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0].x, 5, accuracy: 0.0001)
        XCTAssertEqual(positions[0].y, 7, accuracy: 0.0001)
    }

    func testTwoNodesAreOppositeOnTheCircle() {
        let positions = ContactGraphLayout.circlePositions(count: 2, radius: 100, center: (0, 0))
        XCTAssertEqual(positions.count, 2)
        // 两点关于圆心对称。
        XCTAssertEqual(positions[0].x, -positions[1].x, accuracy: 0.0001)
        XCTAssertEqual(positions[0].y, -positions[1].y, accuracy: 0.0001)
    }

    func testManyNodesEvenlySpacedByAngle() {
        let count = 8
        let positions = ContactGraphLayout.circlePositions(count: count, radius: 50, center: (0, 0))
        XCTAssertEqual(positions.count, count)
        // 每个点到圆心的距离都应等于半径。
        for point in positions {
            let distance = (point.x * point.x + point.y * point.y).squareRoot()
            XCTAssertEqual(distance, 50, accuracy: 0.0001)
        }
        // 相邻两点夹角应均为 360/count 度。
        func angle(_ p: (x: Double, y: Double)) -> Double { atan2(p.y, p.x) }
        let expectedDelta = 2 * Double.pi / Double(count)
        for i in 0..<(count - 1) {
            var delta = angle(positions[i + 1]) - angle(positions[i])
            if delta < 0 { delta += 2 * Double.pi }
            XCTAssertEqual(delta, expectedDelta, accuracy: 0.0001)
        }
    }

    func testRadiusScaling() {
        let small = ContactGraphLayout.circlePositions(count: 4, radius: 10, center: (0, 0))
        let large = ContactGraphLayout.circlePositions(count: 4, radius: 20, center: (0, 0))
        for (s, l) in zip(small, large) {
            XCTAssertEqual(l.x, s.x * 2, accuracy: 0.0001)
            XCTAssertEqual(l.y, s.y * 2, accuracy: 0.0001)
        }
    }
}
