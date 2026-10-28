import XCTest
@testable import LodoIME

/// 快捷输入(rq / sj / xq / nl)与《通用规范汉字表》外单字降权。
final class QuickPhraseTests: XCTestCase {
    let engine = PinyinEngine(lexicon: EngineTests.lexicon)
    /// 2026-10-28 周三 15:05(上海),农历丙午年九月十九。
    let now: Date = {
        var c = DateComponents(year: 2026, month: 10, day: 28, hour: 15, minute: 5)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    func testTexts() {
        XCTAssertEqual(QuickPhrases.texts(for: "rq", now: now, calendar: calendar), ["2026年10月28日", "10月28日 周三", "2026-10-28"])
        XCTAssertEqual(QuickPhrases.texts(for: "sj", now: now, calendar: calendar), ["15:05", "2026-10-28 15:05"])
        XCTAssertEqual(QuickPhrases.texts(for: "xq", now: now, calendar: calendar), ["周三", "星期三"])
        XCTAssertEqual(QuickPhrases.texts(for: "nl", now: now, calendar: calendar), ["农历九月十九", "丙午年九月十九"])
        XCTAssertEqual(QuickPhrases.texts(for: "rqi", now: now, calendar: calendar), [])
        XCTAssertEqual([1, 10, 11, 20, 21, 30].map(QuickPhrases.chineseDay), ["初一", "初十", "十一", "二十", "廿一", "三十"])
    }

    /// 排在词典首选后面:空格照旧上「日期」这类词;选了也不学进用户词。
    func testInsertedAfterTopCandidate() {
        let list = engine.candidates(for: "rq", now: now).candidates
        XCTAssertNotEqual(list.first?.source, .quickPhrase)
        XCTAssertEqual(list[1].source, .quickPhrase, list.prefix(5).map(\.text).description)
        XCTAssertTrue(list[1].text.hasPrefix("2026年"))
        XCTAssertFalse(list[1].answersKey)
        XCTAssertTrue(engine.candidates(for: "riqi", now: now).candidates.allSatisfy { $0.source != .quickPhrase })

        var c = Composition()
        "rq".forEach { c.insert($0) }
        XCTAssertEqual(c.select(list[1], engine: engine), list[1].text)
        XCTAssertTrue(engine.userDictionary.isEmpty)
    }

    func testTableComplete() {
        XCTAssertEqual(CommonCharacters.all.count, 8105)
        XCTAssertTrue(CommonCharacters.isCommon("对"))
        XCTAssertFalse(CommonCharacters.isCommon("對"))
    }

    /// 繁体、异体字排到常用字后面:dui 的前几个单字里没有「對」,但往后翻仍打得出来。
    func testRareCharactersRankBelowCommon() {
        let singles = engine.candidates(for: "dui", rerank: false).candidates.map(\.text).filter { $0.count == 1 }
        XCTAssertFalse(singles.prefix(8).contains("對"), singles.prefix(8).description)
        XCTAssertTrue(engine.candidates(for: "dui", limit: 200, rerank: false).candidates.contains { $0.text == "對" })
        XCTAssertEqual(engine.candidates(for: "ei", rerank: false).candidates.first?.text, "诶")
    }
}
