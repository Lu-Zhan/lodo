import XCTest
@testable import LodoIME

/// 九宫格:输入是 2–9 的数字串,一个数字串能读成好几种拼音,靠词频分。
final class NineKeyTests: XCTestCase {
    let engine = PinyinEngine(lexicon: EngineTests.lexicon)

    func testDigitsDecodeToCommonWords() {
        XCTAssertEqual(engine.candidates(for: "64426").candidates.first?.text, "你好")
        XCTAssertEqual(engine.candidates(for: "94664486").candidates.first?.text, "中国")
        XCTAssertEqual(engine.candidates(for: "64426").segmented, "ni'hao")
    }

    /// 末音节没按完:补全成整词,拼写只写按到的字母。
    func testPartialLastSyllable() {
        let r = engine.candidates(for: "6442")
        XCTAssertTrue(r.candidates.prefix(5).contains { $0.text == "你好" }, "\(r.candidates.prefix(5).map(\.text))")
        XCTAssertEqual(r.segmented.split(separator: "'").first, "ni")
    }

    /// 左边那列:开头的数字能读成哪些拼音,长的在前;选了之后那几位换成字母。
    func testSyllableChoicesAndFixedSpelling() {
        let choices = engine.nineKeySyllables(for: "64426")
        XCTAssertTrue(choices.contains { $0.syllable == "ni" && $0.length == 2 })
        XCTAssertTrue(choices.contains { $0.syllable == "mi" && $0.length == 2 })
        XCTAssertEqual(choices.last?.length, 1)
        var c = Composition()
        "64426".forEach { c.insert($0) }
        c.fixSpelling("mi", consuming: 2)
        XCTAssertEqual(c.remaining, "mi'426")
        let top = engine.candidates(for: c.remaining).candidates.first!
        XCTAssertEqual(top.syllableIDs.first, EngineTests.lexicon.syllableIndex["mi"], top.text)
    }

    /// 定了第一段再选第二段;定过的不被改动。
    func testSecondSegmentChoices() {
        var c = Composition()
        "64426".forEach { c.insert($0) }
        c.fixSpelling("ni", consuming: 2)
        XCTAssertTrue(engine.nineKeySyllables(for: c.remaining).contains { $0.syllable == "hao" && $0.length == 3 })
        c.fixSpelling("hao", consuming: 3)
        XCTAssertEqual(c.remaining, "ni'hao")
        XCTAssertFalse(c.hasNineKeyDigits)
    }
}
