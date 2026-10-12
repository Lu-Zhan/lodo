import XCTest
@testable import LodoCore

final class AgentThinkingPhrasesTests: XCTestCase {
    /// 单个词停 5 秒:同一段里 0 秒和 4.9 秒是同一句。
    func testSingleWordHoldsFiveSeconds() {
        for seed in 0..<40 {
            let first = AgentThinkingPhrases.playlist(seed: seed, language: .zhHans)[0]
            guard first.count == 1 else { continue }
            XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 0, seed: seed, language: .zhHans),
                           AgentThinkingPhrases.text(elapsed: 4.9, seed: seed, language: .zhHans))
            XCTAssertEqual(first[0].duration, 5)
            return
        }
        XCTFail("没找到以单个词开头的种子")
    }

    /// 连续剧按帧推进:倒计时每秒一帧,5s → 4s → … → 1s。
    func testSeriesAdvancesFrameByFrame() throws {
        let seed = try XCTUnwrap((0..<200).first { seed in
            AgentThinkingPhrases.playlist(seed: seed, language: .zhHans)[0].first?.text == "距离爆炸还有 5s"
        })
        XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 0.5, seed: seed, language: .zhHans), "距离爆炸还有 5s")
        XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 1.5, seed: seed, language: .zhHans), "距离爆炸还有 4s")
        XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 4.5, seed: seed, language: .zhHans), "距离爆炸还有 1s")
        XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 5.5, seed: seed, language: .zhHans), "💥 嘭!")
    }

    /// 同一个种子顺序固定;不同种子开头不全一样;播完一圈从头再来。
    func testPlaylistIsDeterministicAndLoops() {
        let a = AgentThinkingPhrases.playlist(seed: 7, language: .en)
        XCTAssertEqual(a, AgentThinkingPhrases.playlist(seed: 7, language: .en))
        let openers = Set((0..<20).map { AgentThinkingPhrases.playlist(seed: $0, language: .en)[0][0].text })
        XCTAssertGreaterThan(openers.count, 3)
        let total = a.reduce(0) { $0 + $1.reduce(0) { $0 + $1.duration } }
        XCTAssertEqual(AgentThinkingPhrases.text(elapsed: 1, seed: 7, language: .en),
                       AgentThinkingPhrases.text(elapsed: total + 1, seed: 7, language: .en))
    }

    /// 中英文段数对得上(每加一句两边都要补)。
    func testLanguagesHaveSameShape() {
        XCTAssertEqual(AgentThinkingPhrases.chineseWords.count, AgentThinkingPhrases.englishWords.count)
        XCTAssertEqual(AgentThinkingPhrases.chineseSeries.map(\.count),
                       AgentThinkingPhrases.englishSeries.map(\.count))
    }
}
