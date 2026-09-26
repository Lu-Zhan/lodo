import XCTest
@testable import LodoCore

final class PinyinIMETests: XCTestCase {
    private var ime: PinyinIME {
        PinyinIME(entries: [
            .init(pinyin: "xian", word: "先", weight: 100),
            .init(pinyin: "xi'an", word: "西安", weight: 100),
            .init(pinyin: "zhong'guo", word: "中国", weight: 100),
            .init(pinyin: "zhong", word: "中", weight: 100),
            .init(pinyin: "guo", word: "国", weight: 100),
        ])
    }

    func testSyllableAndApostrophe() {
        XCTAssertEqual(ime.segments("xian"), ["xian"])
        XCTAssertEqual(ime.segments("xi'an"), ["xi", "an"])
    }

    func testAbbreviationAndLearning() {
        var input = ime
        input.type("zg")
        XCTAssertTrue(input.candidates.contains("中国"))
        input.clear()
        input.type("zhongguo")
        XCTAssertEqual(input.select("中国"), "中国")
        XCTAssertEqual(input.learnedWords()["zhongguo"], "中国")
    }

    func testSegmentedComposition() {
        var input = ime
        input.type("zhongguo")
        XCTAssertNil(input.select("中"))
        XCTAssertEqual(input.select("国"), "中国")
        XCTAssertEqual(input.learnedWords()["zhongguo"], "中国")
    }
}
