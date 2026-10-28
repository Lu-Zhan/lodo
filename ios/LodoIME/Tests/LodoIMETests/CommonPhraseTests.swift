import XCTest
@testable import LodoIME

final class CommonPhraseTests: XCTestCase {
    func testCuratedCorpusDecodesWithFullPinyin() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
            .appendingPathComponent("common-phrases.tsv")
        let engine = PinyinEngine(lexicon: EngineTests.lexicon)
        let lines = try String(contentsOf: url).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 408)
        for line in lines {
            let fields = line.split(separator: "\t")
            let word = String(fields[1])
            let syllables = fields[2].split(separator: " ").map(String.init)
            XCTAssertTrue(engine.lexicon.words(for: syllables).contains(word), word)
            let key = syllables.joined()
            let candidates = engine.candidates(for: key).candidates
            XCTAssertTrue(candidates.prefix(3).contains { $0.text == word && $0.consumed == key.count },
                          "\(word): \(candidates.prefix(3).map(\.text))")
        }
    }

    func testLongPoetryAndAbbreviationAndNineKey() {
        let engine = PinyinEngine(lexicon: EngineTests.lexicon)
        for (key, word) in [("h n c z j t y r b l", "海内存知己天涯若比邻"),
                            ("c f p l h y s z g y f j c h", "长风破浪会有时直挂云帆济沧海"),
                            ("xiexienidebangzhu", "谢谢你的帮助")] {
            let input = key.replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(engine.candidates(for: input).candidates.prefix(5).contains { $0.text == word }, word)
        }
        let key = "chuangqianmingyueguang"
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        let digits = key.map { c in String(groups.firstIndex { $0.contains(c) }! + 2) }.joined()
        XCTAssertTrue(engine.candidates(for: digits).candidates.prefix(5).contains { $0.text == "床前明月光" })
    }
}
