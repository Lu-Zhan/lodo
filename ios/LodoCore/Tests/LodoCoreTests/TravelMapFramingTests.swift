import XCTest
@testable import LodoCore

final class TravelMapFramingTests: XCTestCase {
    private let kyoto = TravelCoordinate(latitude: 35.0, longitude: 135.7)
    private let nara = TravelCoordinate(latitude: 34.6, longitude: 135.8)

    func testFrameFitsPointsIntoUncoveredTopHalf() throws {
        let frame = try XCTUnwrap(TravelMapFraming.frame([kyoto, nara], coveredFraction: 0.5, padding: 1))
        // 包围盒纬度跨度 0.4,露出来一半 ⇒ 整块地图 0.8。
        XCTAssertEqual(frame.latitudeDelta, 0.8, accuracy: 1e-9)
        // 地图顶边 = 中心 + 0.4,露出部分的中点 = 顶边 - 0.2 = 包围盒中点 34.8。
        XCTAssertEqual(frame.center.latitude + frame.latitudeDelta / 2 - 0.2, 34.8, accuracy: 1e-9)
        XCTAssertEqual(frame.center.longitude, 135.75, accuracy: 1e-9)
    }

    func testFrameAlsoAvoidsTopBar() throws {
        let frame = try XCTUnwrap(TravelMapFraming.frame(
            [kyoto, nara], coveredFraction: 0.5, topCoveredFraction: 0.1, padding: 1))
        // 露出 40% ⇒ 整块 1.0;露出部分 = 顶边往下 0.1 到 0.5,中点 = 顶边 - 0.3 = 34.8。
        XCTAssertEqual(frame.latitudeDelta, 1.0, accuracy: 1e-9)
        XCTAssertEqual(frame.center.latitude + 0.5 - 0.3, 34.8, accuracy: 1e-9)
    }

    func testFrameWithoutCoverIsCentered() throws {
        let frame = try XCTUnwrap(TravelMapFraming.frame([kyoto, nara]))
        XCTAssertEqual(frame.center.latitude, 34.8, accuracy: 1e-9)
    }

    func testSinglePointUsesMinimumSpan() throws {
        let frame = try XCTUnwrap(TravelMapFraming.frame([kyoto], coveredFraction: 0.5))
        XCTAssertEqual(frame.longitudeDelta, 0.02, accuracy: 1e-9)
        XCTAssertEqual(frame.latitudeDelta, 0.04, accuracy: 1e-9)
        XCTAssertNil(TravelMapFraming.frame([]))
    }

    func testLegsSkipDuplicatesAndNeedTwoPoints() {
        XCTAssertTrue(TravelMapFraming.legs([kyoto]).isEmpty)
        let legs = TravelMapFraming.legs([kyoto, kyoto, nara])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs.first?.to, nara)
    }

    func testDistanceAndWalking() {
        let near = TravelCoordinate(latitude: 35.0, longitude: 135.71)  // 约 900 米
        XCTAssertEqual(TravelMapFraming.distance(kyoto, near), 911, accuracy: 20)
        XCTAssertTrue(TravelMapFraming.prefersWalking(kyoto, near))
        XCTAssertFalse(TravelMapFraming.prefersWalking(kyoto, nara))
    }
}
