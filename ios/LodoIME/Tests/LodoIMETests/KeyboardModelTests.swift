import XCTest
@testable import LodoIME
@testable import LodoKeyboardModel

final class FakeDocument: TextDocument {
    var text = ""
    var contextBeforeInput: String? { text }
    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

final class KeyboardModelTests: XCTestCase {
    var doc: FakeDocument!
    var session: TypingSession!

    override func setUp() {
        doc = FakeDocument()
        session = TypingSession(engine: PinyinEngine(lexicon: EngineTests.lexicon))
        session.document = doc
    }

    func type(_ s: String) { s.forEach { session.handle(.letter($0)) } }

    // MARK: 布局

    func testRowsFillWidthAndHitFramesCoverArea() {
        let m = KeyboardMetrics.phonePortrait
        for page in [KeyboardPage.letters, .numbers, .symbols] {
            for lang in [InputLanguage.chinese, .english] {
                for globe in [false, true] {
                    let rows = KeyboardLayout.rows(page: page, language: lang, needsGlobe: globe)
                    let placed = KeyboardFrames.place(rows, width: 402, metrics: m)
                    // 每一行最右边的键帽贴到右边距(第二行 9 个字母居中除外)。
                    for r in [0, 2, 3] {
                        let row = placed.filter { abs($0.frame.minY - placed.first { _ in true }!.frame.minY - CGFloat(r) * (m.keyHeight + m.rowSpacing)) < 0.5 }
                        XCTAssertEqual(row.last!.frame.maxX, 402 - m.sideInset, accuracy: 0.5, "\(page) \(lang) \(globe) 第\(r)行")
                    }
                    // 键区里任何一点都归某颗键,而且只归一颗。
                    for x in stride(from: 0.5, to: 402, by: 7) {
                        for y in stride(from: 0.5, to: m.keyAreaHeight(rows: 4), by: 5) {
                            let hits = placed.filter { $0.hitFrame.contains(CGPoint(x: x, y: y)) }.count
                            XCTAssertEqual(hits, 1, "(\(x),\(y)) \(page)")
                        }
                    }
                }
            }
        }
    }

    func testSecondRowGapBelongsToEdgeKeys() {
        let placed = KeyboardFrames.place(KeyboardLayout.rows(page: .letters, language: .chinese, needsGlobe: false),
                                          width: 402, metrics: .phonePortrait)
        let y = placed.first { $0.key.action == .letter("a") }!.frame.midY
        let i = KeyboardFrames.key(at: CGPoint(x: 2, y: y), in: placed)!
        XCTAssertEqual(placed[i].key.action, .letter("a"))
    }

    // MARK: 中文

    func testSpaceCommitsTopCandidate() {
        type("zhongguo")
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.candidates.first?.text, "中国")
        session.handle(.space)
        XCTAssertEqual(doc.text, "中国")
        XCTAssertFalse(session.isComposing)
    }

    func testPartialSelectionThenRest() {
        type("zhongguoren")
        let i = session.candidates.firstIndex { $0.text == "中国" && $0.source == .prefix }!
        session.selectCandidate(at: i)
        XCTAssertEqual(doc.text, "")
        XCTAssertTrue(session.preedit.hasPrefix("中国"))
        session.handle(.space)
        XCTAssertEqual(doc.text, "中国人")
    }

    func testPunctuationCommitsFirst() {
        type("nihao")
        session.handle(.text("，"))
        XCTAssertEqual(doc.text, "你好，")
    }

    func testReturnCommitsLetters() {
        type("iphone")
        session.handle(.returnKey)
        XCTAssertEqual(doc.text, "iphone")
    }

    func testDeleteEditsCompositionFirst() {
        doc.text = "好"
        type("ni")
        session.handle(.delete)
        session.handle(.delete)
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(doc.text, "好")
        session.handle(.delete)
        XCTAssertEqual(doc.text, "")
    }

    func testToggleLanguageKeepsLetters() {
        type("ab")
        session.handle(.toggleLanguage)
        XCTAssertEqual(doc.text, "ab")
        XCTAssertEqual(session.language, .english)
    }

    func testChineseQuotesPair() {
        session.handle(.text("“"))
        session.handle(.text("“"))
        XCTAssertEqual(doc.text, "“”")
    }

    func testShiftLetterInChineseInsertsUppercase() {
        session.handle(.shift)
        session.handle(.letter("a"))
        XCTAssertEqual(doc.text, "A")
        XCTAssertEqual(session.shift, .off)
    }

    // MARK: 英文

    func testEnglishAutoCapitalAndDoubleSpace() {
        session.handle(.toggleLanguage)
        XCTAssertEqual(session.shift, .once) // 空文档开头自动大写
        let t0 = Date()
        "hi".forEach { session.handle(.letter($0), now: t0) }
        XCTAssertEqual(doc.text, "Hi")
        session.handle(.space, now: t0)
        session.handle(.space, now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(doc.text, "Hi. ")
        XCTAssertEqual(session.shift, .once)
    }

    func testDoubleTapShiftLocks() {
        session.handle(.toggleLanguage)
        doc.text = "x"
        session.documentChanged()
        let t0 = Date()
        session.handle(.shift, now: t0)
        session.handle(.shift, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(session.shift, .locked)
        "ab".forEach { session.handle(.letter($0)) }
        XCTAssertEqual(doc.text, "xAB")
    }

    func testSuggestionReplacesPartialWord() {
        struct Fixed: EnglishCompleter { func completions(for word: String) -> [String] { ["hello"] } }
        session.completer = Fixed()
        session.handle(.toggleLanguage)
        "he".forEach { session.handle(.letter($0)) }
        XCTAssertEqual(session.suggestions, ["hello"])
        session.selectSuggestion("Hello")
        XCTAssertEqual(doc.text, "Hello ")
    }

    func testSpaceOnNumbersPageReturnsToLetters() {
        session.handle(.page(.numbers))
        session.handle(.text("1"))
        session.handle(.space)
        XCTAssertEqual(session.page, .letters)
        XCTAssertEqual(doc.text, "1 ")
    }
}

extension KeyboardModelTests {
    func testSwitchDocumentLeavesLettersBehind() {
        let panel = FakeDocument()
        type("ni")
        session.switchDocument(to: panel)
        XCTAssertEqual(doc.text, "ni")
        type("hao")
        session.handle(.space)
        XCTAssertEqual(panel.text, "好")
    }
}

// MARK: - codex 评估后补的边界情况

extension KeyboardModelTests {
    func testEchoOfOwnCommitDoesNotClearNextComposition() {
        type("nihao")
        session.handle(.space)            // 上屏「你好」
        type("zai")                        // 紧接着开始拼下一段
        session.documentChanged()          // 上一次上屏迟到的 textDidChange
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.composition.remaining, "zai")
    }

    func testExternalChangeClearsComposition() {
        type("zai")
        doc.text = "别人改了内容"           // 宿主自己改了(或用户点到了别处)
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
    }

    func testManualShiftOffAtSentenceStartSticks() {
        session.handle(.toggleLanguage)
        XCTAssertEqual(session.shift, .once)
        session.handle(.shift, now: Date())
        XCTAssertEqual(session.shift, .off, "句首手动关掉大写,自动大写不能马上又打开")
        session.handle(.letter("i"))
        XCTAssertEqual(doc.text, "i")
    }

    func testAutoShiftWithdrawnMidSentence() {
        session.handle(.toggleLanguage)
        XCTAssertEqual(session.shift, .once)
        doc.text = "Hello wor"             // 光标被挪到句中
        session.documentChanged()
        XCTAssertEqual(session.shift, .off)
    }

    func testSpaceCommitsSelectedPiecesAfterDeletingRest() {
        type("zhongguoren")
        let i = session.candidates.firstIndex { $0.text == "中国" && $0.source == .prefix }!
        session.selectCandidate(at: i)
        session.handle(.delete)
        session.handle(.delete)
        session.handle(.delete)            // 「ren」删光,只剩已选的「中国」
        XCTAssertTrue(session.isComposing)
        session.handle(.space)
        XCTAssertEqual(doc.text, "中国")
        XCTAssertFalse(session.isComposing)
    }

    func testSeparatorSplitsSyllables() {
        type("xi")
        session.handle(.separator)
        session.handle(.separator)         // 不能连着两个
        XCTAssertEqual(session.composition.remaining, "xi'")
        type("an")
        XCTAssertEqual(session.candidates.first?.text, "西安")
    }

    func testSeparatorWithoutCompositionTypesComma() {
        session.handle(.separator)
        XCTAssertEqual(doc.text, ",")
    }

    func testWordDeletionLength() {
        XCTAssertEqual(TypingSession.wordDeletionLength("hello world"), 5)
        XCTAssertEqual(TypingSession.wordDeletionLength("hello world  "), 7)
        XCTAssertEqual(TypingSession.wordDeletionLength("你好"), 1)
        XCTAssertEqual(TypingSession.wordDeletionLength(""), 0)
        doc.text = "see you"
        session.handle(.deleteWord)
        XCTAssertEqual(doc.text, "see ")
    }

    /// 第三行照系统键盘:shift / 删除 45pt 贴边,z…m 居中、正好落在 s…k 底下(真机截图)。
    func testThirdRowEdgeKeysAndAlignedLetters() {
        let m = KeyboardMetrics.phonePortrait
        let placed = KeyboardFrames.place(KeyboardLayout.rows(page: .letters, language: .chinese, needsGlobe: false),
                                          width: 402, metrics: m)
        func frame(_ a: KeyAction) -> CGRect { placed.first { $0.key.action == a }!.frame }
        XCTAssertEqual(frame(.shift).minX, m.sideInset, accuracy: 0.5)
        XCTAssertEqual(frame(.shift).width, m.edgeKeyWidth, accuracy: 0.5)
        XCTAssertEqual(frame(.delete).maxX, 402 - m.sideInset, accuracy: 0.5)
        XCTAssertEqual(frame(.letter("z")).width, frame(.letter("q")).width, accuracy: 0.5)
        XCTAssertEqual(frame(.letter("z")).midX, frame(.letter("s")).midX, accuracy: 0.5)
        XCTAssertEqual(frame(.letter("m")).midX, frame(.letter("k")).midX, accuracy: 0.5)
        // 底行:回车 2.5 格,和 o、p 两颗加中间键缝等宽再多半格。
        XCTAssertEqual(frame(.returnKey).maxX, 402 - m.sideInset, accuracy: 0.5)
    }
}

final class UserDictionaryIndexTests: XCTestCase {
    func testPrefixesFollowLearnAndForget() {
        var dict = UserDictionary()
        dict.learn("中国人", ids: [1, 2, 3])
        XCTAssertTrue(dict.hasPhrase(withPrefix: [1, 2]))
        dict.forget("中国人", ids: [1, 2, 3])
        XCTAssertFalse(dict.hasPhrase(withPrefix: [1, 2]))
        XCTAssertTrue(dict.isEmpty)
    }

    func testDecodedDictionaryRebuildsIndex() throws {
        var dict = UserDictionary()
        dict.learn("西安", ids: [7, 8])
        let decoded = try JSONDecoder().decode(UserDictionary.self, from: JSONEncoder().encode(dict))
        XCTAssertTrue(decoded.hasPhrase(withPrefix: [7]))
    }
}

// MARK: - codex 复核后补的

final class NilContextDocument: TextDocument {
    var deletes = 0
    var contextBeforeInput: String? { nil }
    func insertText(_ text: String) {}
    func deleteBackward() { deletes += 1 }
}

extension KeyboardModelTests {
    func testRawLettersMatchWhatGetsCommitted() {
        type("zhongguoren")
        let i = session.candidates.firstIndex { $0.text == "中国" && $0.source == .prefix }!
        session.selectCandidate(at: i)
        session.handle(.separator)
        XCTAssertEqual(session.rawLetters, "中国ren")
        session.commitRawLetters()
        XCTAssertEqual(doc.text, "中国ren")
    }

    func testCursorMoveRightAfterCommitStillClears() {
        type("nihao")
        session.handle(.space)            // 上屏「你好」
        type("zai")
        doc.text = "你"                    // 刚上屏就把光标挪到了中间:不是回声
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
    }

    func testDeleteWordWithoutContextFallsBackToSingleDelete() {
        let blind = NilContextDocument()
        session.document = blind
        session.handle(.deleteWord)
        XCTAssertEqual(blind.deletes, 1)
    }
}

extension KeyboardModelTests {
    func testCursorMovedToSameSuffixIsNotEcho() {
        doc.text = "你好,"
        type("nihao")
        session.handle(.space)            // 「你好,你好」
        session.documentChanged()          // 这次上屏的回声:认过就作废
        type("zai")
        doc.text = "你好"                  // 光标挪到第一个「你好」后面,前文后缀和刚上屏的一样
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
    }
}

extension KeyboardModelTests {
    func testStaleEchoIsNotReusedAfterMovingBack() {
        type("nihao")
        session.handle(.space)            // 上屏「你好」,还没收到回调
        type("zai")
        doc.text = "别处"                  // 挪到别处:不是回声,清掉;旧的回声同时作废
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
        type("zai")
        doc.text = "你好"                  // 再挪回原来上屏的位置
        session.documentChanged()
        XCTAssertFalse(session.isComposing, "作废了的回声不能再被认出来")
    }
}

/// 数一共问了宿主几次光标前的文字(扩展里每次都是跨进程)。
final class CountingDocument: TextDocument {
    var text = ""
    var reads = 0
    var contextBeforeInput: String? { reads += 1; return text }
    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

extension KeyboardModelTests {
    /// 拼音后直接按标点:上屏的是屏幕上那个首选。
    func testPunctuationCommitsDisplayedFirstCandidate() {
        type("nihao")
        let shown = session.candidates.first!.text
        session.handle(.text("，"))
        XCTAssertEqual(doc.text, shown + "，")
    }

    /// 一次按键只问一次宿主;还在拼时宿主的回调不重新解码,候选原样不动。
    func testContextReadOncePerEventAndEchoSkipsDecode() {
        let counting = CountingDocument()
        session.document = counting
        session.handle(.letter("n"))
        counting.reads = 0
        session.handle(.letter("i"))
        XCTAssertLessThanOrEqual(counting.reads, 1)
        let before = session.candidates.map(\.text)
        counting.reads = 0
        session.documentChanged()
        XCTAssertEqual(counting.reads, 1)
        XCTAssertEqual(session.candidates.map(\.text), before)
        XCTAssertTrue(session.isComposing)
        counting.reads = 0
        session.handle(.text("，"))
        XCTAssertLessThanOrEqual(counting.reads, 1)
    }
}

/// 像 UITextView 那样支持标记文字的宿主:光标前的文字连着标记文字一起给。
final class MarkedDocument: TextDocument {
    var text = ""
    var marked = ""
    var contextBeforeInput: String? { text + marked }
    func insertText(_ t: String) { text += marked + t; marked = "" }
    func deleteBackward() { if !marked.isEmpty { marked = "" } else if !text.isEmpty { text.removeLast() } }
    var supportsMarkedText: Bool { true }
    func setMarkedText(_ t: String) { marked = t }
    func unmarkText() { text += marked; marked = "" }
}

extension KeyboardModelTests {
    /// 拼音写在输入框里(带空格切分),选完换成汉字;中途宿主回调不清组合。
    func testPinyinIsMarkedTextInHost() {
        let host = MarkedDocument()
        host.text = "说"
        session.document = host
        type("nihao")
        XCTAssertEqual(host.marked, "ni hao")
        XCTAssertFalse(session.showsPreeditInBar)
        session.documentChanged() // 写标记文字引起的回调
        XCTAssertTrue(session.isComposing)
        session.handle(.space)
        XCTAssertEqual(host.text, "说" + reference(for: "nihao"))
        XCTAssertEqual(host.marked, "")
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
    }

    /// 删光拼音:输入框里不留东西。用户挪了光标:组合丢掉。
    func testMarkedTextClearedOnDeleteAndExternalChange() {
        let host = MarkedDocument()
        session.document = host
        type("ni")
        session.handle(.delete); session.handle(.delete)
        XCTAssertEqual(host.marked, "")
        XCTAssertEqual(host.text, "")
        type("ni")
        host.text = "别处"; host.marked = "" // 宿主自己改了内容(挪光标时它会确认掉标记文字)
        session.documentChanged()
        XCTAssertFalse(session.isComposing)
    }

    /// 拼音后按标点:汉字换掉标记文字,标点接在后面。
    func testPunctuationAfterMarkedPinyin() {
        let host = MarkedDocument()
        session.document = host
        type("nihao")
        session.handle(.text("，"))
        XCTAssertEqual(host.text, reference(for: "nihao") + "，")
        XCTAssertEqual(host.marked, "")
    }

    private func reference(for input: String) -> String {
        PinyinEngine(lexicon: EngineTests.lexicon).candidates(for: input).candidates.first!.text
    }
}
