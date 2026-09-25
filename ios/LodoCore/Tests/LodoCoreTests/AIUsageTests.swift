import XCTest
@testable import LodoCore

/// token 用量统计的纯逻辑。基准时刻固定,不依赖真实时钟。
final class AIUsageTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - 千位缩写

    func testFormatCount() {
        XCTAssertEqual(AIUsage.formatCount(0), "0")
        XCTAssertEqual(AIUsage.formatCount(999), "999")
        XCTAssertEqual(AIUsage.formatCount(1000), "1k")
        XCTAssertEqual(AIUsage.formatCount(1149), "1.1k")
        XCTAssertEqual(AIUsage.formatCount(9999), "10k")
        XCTAssertEqual(AIUsage.formatCount(12_345), "12k")
    }

    // MARK: - 速度

    func testSpeedNeedsAWindow() {
        // 刚吐出第一片时分母太小,除出来是天文数字,不给速度。
        let fresh = AIUsage(outputTokens: 3, generatingSeconds: 0.05)
        XCTAssertNil(fresh.tokensPerSecond)
        let settled = AIUsage(outputTokens: 320, generatingSeconds: 10)
        XCTAssertEqual(settled.tokensPerSecond ?? 0, 32, accuracy: 0.001)
        // 一个 token 都没出来也不给。
        XCTAssertNil(AIUsage(outputTokens: 0, generatingSeconds: 5).tokensPerSecond)
    }

    // MARK: - 标题行文案

    func testBadge() {
        let exact = AIUsage(inputTokens: 1120, outputTokens: 320, isEstimated: false,
                            generatingSeconds: 10)
        XCTAssertEqual(exact.badge, "↑1.1k ↓320 · 32 tok/s")
        // 没拿到 usage:只报输出、打 ≈(客户端不知道 prompt 多大)。
        let estimated = AIUsage(outputTokens: 320, isEstimated: true, generatingSeconds: 10)
        XCTAssertEqual(estimated.badge, "↓≈320 · 32 tok/s")
        // 进行中只报速度。
        let streaming = AIUsage(outputTokens: 320, isEstimated: true,
                                generatingSeconds: 10, isStreaming: true)
        XCTAssertEqual(streaming.badge, "32 tok/s")
        // 什么都没有时不占位。
        XCTAssertNil(AIUsage().badge)
    }

    // MARK: - 累加器

    func testAccumulatesAcrossRequests() {
        var acc = AIUsageAccumulator()
        // 第一次请求:精确 usage。
        XCTAssertTrue(acc.markDelta(at: t0))
        acc.report(inputTokens: 900, outputTokens: 200)
        acc.endRequest(at: t0.addingTimeInterval(4))
        // 第二次请求:中间隔了一次联网搜索(6 秒纯等待,不该算进生成时长)。
        XCTAssertTrue(acc.markDelta(at: t0.addingTimeInterval(10)))
        acc.report(inputTokens: 1_100, outputTokens: 120)
        acc.endRequest(at: t0.addingTimeInterval(16))

        let usage = acc.snapshot(at: t0.addingTimeInterval(20))
        XCTAssertEqual(usage.requests, 2)
        XCTAssertEqual(usage.inputTokens, 2_000)
        XCTAssertEqual(usage.outputTokens, 320)
        XCTAssertFalse(usage.isEstimated)
        XCTAssertFalse(usage.isStreaming)
        // 4 + 6,中间那 6 秒等待不算。
        XCTAssertEqual(usage.generatingSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(usage.tokensPerSecond ?? 0, 32, accuracy: 0.001)
    }

    func testFallsBackToDeltaCountWhenUsageMissing() {
        var acc = AIUsageAccumulator()
        for index in 0..<5 {
            _ = acc.markDelta(at: t0.addingTimeInterval(Double(index)))
        }
        acc.endRequest(at: t0.addingTimeInterval(5))
        let usage = acc.snapshot(at: t0.addingTimeInterval(5))
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertTrue(usage.isEstimated)
        XCTAssertNil(usage.inputTokens)
    }

    func testOneMissingReportTaintsTheWholeTurn() {
        var acc = AIUsageAccumulator()
        _ = acc.markDelta(at: t0)
        acc.report(inputTokens: 900, outputTokens: 200)
        acc.endRequest(at: t0.addingTimeInterval(4))
        // 第二次没报 usage:整轮的数字都掺了估算值。
        _ = acc.markDelta(at: t0.addingTimeInterval(5))
        _ = acc.markDelta(at: t0.addingTimeInterval(6))
        acc.endRequest(at: t0.addingTimeInterval(7))
        let usage = acc.snapshot(at: t0.addingTimeInterval(7))
        XCTAssertEqual(usage.outputTokens, 202)
        XCTAssertTrue(usage.isEstimated)
    }

    func testInFlightRequestCountsAsEstimate() {
        var acc = AIUsageAccumulator()
        for index in 0..<4 {
            _ = acc.markDelta(at: t0.addingTimeInterval(Double(index)))
        }
        let usage = acc.snapshot(at: t0.addingTimeInterval(4))
        XCTAssertTrue(usage.isStreaming)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.generatingSeconds, 4, accuracy: 0.001)
    }

    func testDiscardDropsInFlightRequest() {
        var acc = AIUsageAccumulator()
        _ = acc.markDelta(at: t0)
        _ = acc.markDelta(at: t0.addingTimeInterval(1))
        // 流式失败要退回一次性请求:这条流上数过的作废,免得同一次逻辑请求数两遍。
        acc.discardRequest()
        let empty = acc.snapshot(at: t0.addingTimeInterval(2))
        XCTAssertEqual(empty.outputTokens, 0)
        XCTAssertEqual(empty.requests, 0)
        XCTAssertFalse(empty.isStreaming)
    }

    func testNonStreamRequestUsesWholeRequestWindow() {
        var acc = AIUsageAccumulator()
        // 没有增量:生成时长只能按整次请求算。
        acc.beginRequest(at: t0)
        acc.report(inputTokens: 900, outputTokens: 200)
        acc.endRequest(at: t0.addingTimeInterval(8))
        let usage = acc.snapshot(at: t0.addingTimeInterval(8))
        XCTAssertEqual(usage.generatingSeconds, 8, accuracy: 0.001)
        XCTAssertEqual(usage.outputTokens, 200)
        XCTAssertFalse(usage.isEstimated)
    }

    func testEndRequestWithoutARequestIsANoop() {
        var acc = AIUsageAccumulator()
        acc.endRequest(at: t0)
        XCTAssertEqual(acc.snapshot(at: t0).requests, 0)
    }

    // MARK: - 推给 UI 的节流

    func testDeltaPublishThrottle() {
        var acc = AIUsageAccumulator()
        XCTAssertTrue(acc.markDelta(at: t0))
        XCTAssertFalse(acc.markDelta(at: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(acc.markDelta(at: t0.addingTimeInterval(AIUsageAccumulator.publishInterval)))
    }
}
