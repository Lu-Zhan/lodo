import XCTest
@testable import LodoIME
import LodoReranker

final class RerankerTests: XCTestCase {
    static let model = ModelReranker.bundled()

    func testBundledModelLoadsWithAttribution() throws {
        let model = try XCTUnwrap(Self.model)
        // 语料署名在权重头里,设置页「致谢」照抄它。
        XCTAssertTrue(model.attribution.contains("C4"))
        XCTAssertTrue(model.attribution.contains("LCCC"))
    }

    func testPicksByContext() throws {
        let model = try XCTUnwrap(Self.model)
        let pick = model.best(context: "", candidates: [
            .init(text: "请你在说一遍", answersKey: true, trustedDictionaryHit: false),
            .init(text: "请你再说一遍", answersKey: true, trustedDictionaryHit: false),
        ])
        XCTAssertEqual(pick, 1)
    }

    func testDeclinesTrustedLeaderAndPrefixes() throws {
        let model = try XCTUnwrap(Self.model)
        XCTAssertNil(model.best(context: "", candidates: [
            .init(text: "请你在说一遍", answersKey: true, trustedDictionaryHit: true),
            .init(text: "请你再说一遍", answersKey: true, trustedDictionaryHit: false),
        ]))
        // 只吃掉一截键的前缀词不参与比较。
        XCTAssertNil(model.best(context: "", candidates: [
            .init(text: "请你在说一遍", answersKey: true, trustedDictionaryHit: false),
            .init(text: "请你再说一遍", answersKey: false, trustedDictionaryHit: false),
        ]))
    }

    func testEngineWithModelFixesHomophone() throws {
        let engine = PinyinEngine(lexicon: EngineTests.lexicon, reranker: try XCTUnwrap(Self.model))
        XCTAssertEqual(engine.candidates(for: "qingnizaishuoyibian").candidates.first?.text, "请你再说一遍")
        // 预编辑只要切分,不调模型。
        XCTAssertEqual(engine.candidates(for: "qingnizaishuoyibian", limit: 1, rerank: false).segmented,
                       "qing'ni'zai'shuo'yi'bian")
    }

    func testUserWordIsTrusted() {
        let user = Candidate(text: "x", source: .user, consumed: 1, syllableIDs: [0], corrected: false)
        XCTAssertTrue(user.trustedDictionaryHit)
        let fuzzed = Candidate(text: "x", source: .user, consumed: 1, syllableIDs: [0], corrected: true)
        XCTAssertFalse(fuzzed.trustedDictionaryHit)
    }
}
