import XCTest
import LodoIME
@testable import LodoKeyboardModel

/// 后台解码(`BackgroundDecoder`)下的打字:候选慢一拍时,上屏的仍然是对的那一个。
final class TypingSessionAsyncTests: XCTestCase {
    var doc: FakeDocument!
    var session: TypingSession!
    /// 同一份词库、不接重排器的同步引擎,当「标准答案」。
    var reference: PinyinEngine!

    override func setUp() {
        doc = FakeDocument()
        session = TypingSession(engine: PinyinEngine(lexicon: EngineTests.lexicon))
        session.decoder = BackgroundDecoder(lexicon: EngineTests.lexicon, userDictionary: UserDictionary())
        session.document = doc
        reference = PinyinEngine(lexicon: EngineTests.lexicon)
    }

    func type(_ s: String) { s.forEach { session.handle(.letter($0)) } }

    /// 等后台结果回到主线程。
    func waitForCandidates(file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "候选跟上")
        func poll() {
            if session.candidatesAreCurrent && !session.candidates.isEmpty { done.fulfill() } else {
                DispatchQueue.main.async(execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 5)
    }

    func testCandidatesArriveAsynchronously() {
        type("nihao")
        waitForCandidates()
        XCTAssertEqual(session.candidates.first?.text, reference.candidates(for: "nihao").candidates.first?.text)
        XCTAssertEqual(session.preedit, "ni'hao")
    }

    /// 打完马上按空格(候选还没回来):当场补解一次,上屏的是这串拼音的首选。
    func testSpaceBeforeResultCommitsCurrentBest() {
        type("nihao")
        session.handle(.space)
        XCTAssertEqual(doc.text, reference.candidates(for: "nihao").candidates.first?.text)
        XCTAssertFalse(session.isComposing)
    }

    /// 点的是上一串拼音的候选(手快又打了个字母):点的是什么就上什么,多打的字母接着拼。
    func testTappingStaleCandidateKeepsWhatWasTapped() {
        type("ni")
        waitForCandidates()
        let tapped = session.candidates.first { $0.text == "你" }!
        session.handle(.letter("h"))
        XCTAssertFalse(session.candidatesAreCurrent)
        session.select(tapped, decodedFor: "ni")
        XCTAssertEqual(session.composition.remaining, "h")
        XCTAssertEqual(session.composition.pieces.map(\.text), ["你"])
    }

    /// 删过字母后点旧候选:它吃的拼音已经不在了,不能硬上。
    func testStaleCandidateAfterDeleteIsNotForced() {
        type("nihao")
        waitForCandidates()
        let tapped = session.candidates.first { $0.text == "你好" }!
        "hao".forEach { _ in session.handle(.delete) } // 剩 ni,「你好」已经对不上了
        session.select(tapped, decodedFor: "nihao")
        XCTAssertEqual(doc.text, "")
        XCTAssertTrue(session.isComposing)
    }

    /// 上屏后再打同样的字母:上一轮还在路上的结果不能当成这一轮的(上文、已选片段都变了)。
    func testResultFromPreviousCompositionIsDropped() {
        type("ni")
        session.handle(.space) // 上一轮的后台请求还没回来就上屏了
        let committed = doc.text
        type("ni")
        XCTAssertFalse(session.candidatesAreCurrent)
        waitForCandidates()
        XCTAssertTrue(session.candidatesAreCurrent)
        session.handle(.space)
        XCTAssertTrue(doc.text.hasPrefix(committed))
        XCTAssertGreaterThan(doc.text.count, committed.count)
    }
}
