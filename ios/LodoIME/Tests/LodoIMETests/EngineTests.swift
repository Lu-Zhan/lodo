import XCTest
@testable import LodoIME
import LodoReranker

final class EngineTests: XCTestCase {
    static let lexicon = try! Lexicon.bundled()
    var engine: PinyinEngine!

    override func setUp() { engine = PinyinEngine(lexicon: Self.lexicon) }

    func top(_ input: String, _ n: Int = 5) -> [String] {
        engine.candidates(for: input).candidates.prefix(n).map(\.text)
    }

    func testLexiconLoads() {
        XCTAssertEqual(Self.lexicon.syllables.count, 411)
        XCTAssertEqual(Self.lexicon.words(for: ["zhong", "guo"]).first, "中国")
    }

    func testWholeKeyWord() {
        XCTAssertEqual(top("zhongguo").first, "中国")
        XCTAssertEqual(top("nihao").first, "你好")
    }

    func testSegmentationAmbiguityKeepsBothReadings() {
        let list = top("xian", 30)
        XCTAssertTrue(list.contains("先") || list.contains("现"))
        XCTAssertTrue(list.contains("西安"))
        XCTAssertEqual(top("xi'an").first, "西安")
    }

    func testAbbreviation() {
        XCTAssertTrue(top("zg", 5).contains("中国"))
        XCTAssertTrue(top("bjdx", 5).contains("北京大学"))
    }

    func testPartialLastSyllable() {
        XCTAssertTrue(top("zhongg", 5).contains("中国"))
    }

    func testSentenceAssembly() {
        XCTAssertEqual(top("wojintianqushangban").first, "我今天去上班")
    }

    func testTypoCorrection() {
        let c = engine.candidates(for: "xign").candidates
        XCTAssertTrue(c.prefix(5).contains { $0.text == "行" || $0.text == "性" })
        XCTAssertTrue(c.first?.corrected ?? false)
    }

    func testMissingVowelInsideSentence() {
        let choices = engine.candidates(for: "nihaya").candidates
        XCTAssertEqual(choices.first?.text, "你好呀")
        XCTAssertTrue(choices.first?.corrected == true)
        if let model = ModelReranker.bundled() {
            engine.reranker = model
            XCTAssertEqual(engine.candidates(for: "nihaya").candidates.first?.text, "你好呀")
        }
        engine.correctionEnabled = false
        XCTAssertFalse(engine.candidates(for: "nihaya").candidates.contains { $0.text == "你好呀" && $0.corrected })
    }

    func testPersonalNameAppearsAsCandidate() {
        engine.personalDictionary = PersonalDictionary(
            words: [.init(text: "张小满", pinyin: "zhang xiao man")], lexicon: Self.lexicon)
        let choices = engine.candidates(for: "zhangxiaoman").candidates
        XCTAssertTrue(choices.contains { $0.text == "张小满" && $0.source == .user })
        XCTAssertTrue(engine.candidates(for: "zxm").candidates.contains { $0.text == "张小满" })
        let digits = Syllabifier.nineKeyCode("zhangxiaoman")
        XCTAssertTrue(engine.candidates(for: digits).candidates.contains { $0.text == "张小满" })
    }

    func testCompositionPartialSelect() {
        var comp = Composition()
        "zhongguoren".forEach { comp.insert($0) }
        let prefix = engine.candidates(for: comp.remaining).candidates.first { $0.text == "中国" }!
        XCTAssertNil(comp.select(prefix, engine: engine))
        XCTAssertEqual(comp.remaining, "ren")
        let ren = engine.candidates(for: comp.remaining).candidates.first { $0.text == "人" }!
        XCTAssertEqual(comp.select(ren, engine: engine), "中国人")
        // 学过之后整串直接出。
        XCTAssertEqual(top("zhongguoren").first, "中国人")
    }

    func testBackspaceUndoesSelection() {
        var comp = Composition()
        "nihao".forEach { comp.insert($0) }
        guard let ni = engine.candidates(for: "nihao").candidates.first(where: { $0.text == "你" && $0.source == .prefix }) else {
            XCTFail("missing exact prefix")
            return
        }
        _ = comp.select(ni, engine: engine)
        XCTAssertEqual(comp.remaining, "hao")
        comp.remaining.forEach { _ in comp.backspace() }
        comp.backspace()
        XCTAssertEqual(comp.remaining, "ni")
        XCTAssertTrue(comp.pieces.isEmpty)
    }

    func testUserLearningPromotes() {
        let before = top("shijian", 10)
        let target = before.first { $0 != before[0] }!
        let cand = engine.candidates(for: "shijian").candidates.first { $0.text == target }!
        var comp = Composition()
        "shijian".forEach { comp.insert($0) }
        _ = comp.select(cand, engine: engine)
        XCTAssertEqual(top("shijian").first, target)
    }

    func testRerankerNotCalledForTrustedHit() {
        struct Spy: Reranker { let hit: @Sendable () -> Void
            func best(context: String, candidates: [RerankCandidate]) -> Int? { hit(); return nil } }
        final class Box: @unchecked Sendable { var n = 0 }
        let box = Box()
        engine.reranker = Spy { box.n += 1 }
        _ = engine.candidates(for: "zhongguo")
        XCTAssertEqual(box.n, 0)
        _ = engine.candidates(for: "wojintianqushangban")
        XCTAssertEqual(box.n, 1)
    }

    func testFuzzy() {
        engine.fuzzy = [.zZh]
        XCTAssertTrue(top("zongguo", 5).contains("中国"))
    }

    func testUnknownLettersStillProduceCandidate() {
        XCTAssertFalse(engine.candidates(for: "vvv").candidates.isEmpty)
    }

    func testLatency() {
        measure { _ = engine.candidates(for: "womenyiqiquchifanbaranhouqukandianying") }
    }
}
