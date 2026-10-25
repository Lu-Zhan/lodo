import Foundation
import LodoIME

/// 键盘写字的对象:扩展里是 `textDocumentProxy`,测试里是假的。
public protocol TextDocument: AnyObject {
    var contextBeforeInput: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

/// 英文补全(扩展里用 `UITextChecker`,这一层不碰 UIKit)。
public protocol EnglishCompleter {
    func completions(for word: String) -> [String]
}

public enum ShiftState: Sendable {
    case off
    /// 只管下一个字母。
    case once
    /// 双击 shift:大写锁定。
    case locked
}

public enum Autocapitalization: Sendable {
    case none, words, sentences, allCharacters
}

/// 一次键盘会话的打字逻辑:按键 → 组合态 / 上屏。视图只管画和收触摸,判断都在这里。
public final class TypingSession {
    public let engine: PinyinEngine
    public weak var document: TextDocument?
    public var completer: EnglishCompleter?

    public private(set) var page: KeyboardPage = .letters
    public private(set) var language: InputLanguage
    public private(set) var shift: ShiftState = .off
    public private(set) var composition = Composition()
    /// 拼音候选(中文且正在拼时)。
    public private(set) var candidates: [Candidate] = []
    /// 英文补全(英文且光标前是半个单词时)。
    public private(set) var suggestions: [String] = []
    public var autocapitalization: Autocapitalization = .sentences

    /// 状态变了(候选、页、shift),视图据此重画。
    public var onChange: (() -> Void)?

    private var lastShiftTap: Date?
    private var lastSpace: Date?
    /// 当前的 `.once` 是自动大写给的(不是用户按的):挪到句中要撤掉。
    private var shiftIsAuto = false
    /// 用户在这个位置亲手按过 shift:自动大写别再改它,直到光标前的文字变了。
    private var shiftOverridden = false
    /// 开始拼音那一刻光标前的文字。拼音不写进宿主,所以宿主的文字变了只可能是外部改动;
    /// 没变就是我们自己上一次上屏迟到的 `textDidChange`,不能清掉正在拼的字。
    private var compositionAnchor: String?
    /// 我们最后一次写宿主(上屏、删除)之后,光标前应有的文字。之后来的 `textDidChange` 是不是它的回声,
    /// 就看光标前的文字是不是正好是它(宿主的 context 可能慢一拍,所以不能只比开始拼音时的锚点)。
    private var expectedEcho: String?
    /// 上一次解码的切分(zhong'guo),预编辑直接用它,不为了显示再解一遍。
    private var segmented = ""
    static let doubleTap: TimeInterval = 0.35

    public init(engine: PinyinEngine, language: InputLanguage = .chinese) {
        self.engine = engine
        self.language = language
    }

    public var isComposing: Bool { !composition.isEmpty }

    /// 候选栏上方那一行:已选的字 + 剩下拼音的切分(zhong'guo)。
    public var preedit: String { composition.pieces.map(\.text).joined() + segmented }

    // MARK: - 按键

    public func handle(_ action: KeyAction, now: Date = Date()) {
        if action != .shift {
            lastShiftTap = nil      // 中间按了别的键,就不算双击 shift
            shiftOverridden = false // 位置变了,自动大写重新说了算
        }
        switch action {
        case .letter(let c): typeLetter(c)
        case .text(let t): typeText(t)
        case .shift: tapShift(now: now)
        case .delete: delete()
        case .deleteWord: deleteWord()
        case .separator: separator()
        case .space: space(now: now)
        case .returnKey: returnKey()
        case .page(let p):
            page = p
        case .toggleLanguage:
            commitRaw()
            language = language == .chinese ? .english : .chinese
            page = .letters
            if shift == .once { shift = .off }
            shiftIsAuto = false
        case .nextKeyboard:
            break // 由视图交给系统
        }
        if action != .space { lastSpace = nil }
        refresh()
    }

    /// 选候选栏里的第 i 条。
    public func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        if let text = composition.select(candidates[index], engine: engine) { insert(text) }
        refresh()
    }

    /// 选一条英文补全:替换掉光标前那半个单词,后面补个空格。
    public func selectSuggestion(_ word: String) {
        let partial = Self.trailingWord(document?.contextBeforeInput ?? "")
        for _ in partial { deleteBackwardInDocument() }
        insert(word + " ")
        refresh()
    }

    /// 宿主的文字或光标变了(`textDidChange`):只有光标前的文字确实和开始拼音时不一样
    /// (用户点到别处、宿主自己改了内容)才丢掉没上屏的拼音;然后重算自动大写。
    public func documentChanged() {
        let current = Self.anchor(document?.contextBeforeInput)
        // 只认「光标前正好是我们最后一次编辑后该有的样子」,而且每次回调都把它作废——
        // 不管这次是不是回声,留着旧值以后挪回原处会被误认(codex 复核指出)。
        // 光看后缀也不行:前文里本来就有同样的字时,把光标挪过去也会对上。
        let isEcho = current == expectedEcho
        expectedEcho = nil
        if isComposing, let anchor = compositionAnchor, anchor != current {
            if isEcho {
                compositionAnchor = current // 自己上一次编辑的回声:跟上宿主,别清
            } else {
                // 用户挪了光标、换了输入框、宿主自己改了内容:丢掉没上屏的拼音。
                composition.clear()
                compositionAnchor = nil
            }
        }
        shiftOverridden = false
        refresh()
    }

    /// 换写字的对象(打开/关掉 lodo 面板时):先把正在拼的字母原样留在原来那边。
    public func switchDocument(to document: TextDocument) {
        commitRaw()
        self.document = document
        expectedEcho = nil // 换了写字的对象,上一边的回声不作数
        refresh()
    }

    /// 候选栏里「原样字母」那一项显示的文字,也正是点了之后上屏的文字:已选的字 + 剩下的字母(不带分隔符)。
    public var rawLetters: String {
        composition.pieces.map(\.text).joined() + composition.remaining.replacingOccurrences(of: "'", with: "")
    }

    /// 点了「原样字母」:按显示的那样上屏。
    public func commitRawLetters() {
        guard isComposing else { return }
        let text = rawLetters
        composition.clear()
        insert(text)
        refresh()
    }

    /// 键盘收起前把正在拼的字母原样留下,不吞掉用户的输入。
    public func commitRaw() {
        guard isComposing else { return }
        insert(composition.commitRaw())
    }

    // MARK: -

    private func typeLetter(_ c: Character) {
        let upper = shift != .off
        if shift == .once { shift = .off; shiftIsAuto = false }
        if language == .chinese && !upper {
            if !isComposing { compositionAnchor = Self.anchor(document?.contextBeforeInput) }
            composition.insert(c)
            return
        }
        // 中文页按住 shift 打的大写字母直接上屏(人名、缩写),先把正在拼的提交掉。
        commitBest()
        insert(upper ? c.uppercased() : String(c))
    }

    private func typeText(_ t: String) {
        // 拼到一半打标点/数字:先上首选,和系统拼音一致。
        commitBest()
        insert(Punctuation.resolveQuote(t, before: document?.contextBeforeInput ?? ""))
    }

    /// 长按「，」:拼音拼到一半时是分隔符(xi'an 和 xian 分开),没在拼时打半角逗号。
    private func separator() {
        if isComposing {
            composition.insert("'")
        } else {
            insert(",")
        }
    }

    private func tapShift(now: Date) {
        shiftOverridden = true
        shiftIsAuto = false
        if let last = lastShiftTap, now.timeIntervalSince(last) < Self.doubleTap {
            shift = .locked
            lastShiftTap = nil
            return
        }
        lastShiftTap = now
        shift = shift == .off ? .once : .off
    }

    private func delete() {
        if isComposing {
            composition.backspace()
        } else {
            deleteBackwardInDocument()
        }
    }

    /// 删除键按住久了按词删:英文删到上一个单词开头(连同中间的空格),
    /// 其他文字(中文没有空格分词)仍一个字一个字删;拼音组合始终逐字母撤回。
    private func deleteWord() {
        if isComposing { return composition.backspace() }
        // 宿主不给前文(有的输入框就是拿不到):退回逐字删,长按删除不能停。
        guard let before = document?.contextBeforeInput, !before.isEmpty else { return deleteBackwardInDocument() }
        let count = Self.wordDeletionLength(before)
        for _ in 0..<count { deleteBackwardInDocument() }
    }

    static func wordDeletionLength(_ before: String) -> Int {
        let chars = Array(before)
        var i = chars.count
        while i > 0, chars[i - 1] == " " { i -= 1 }
        let isWordChar: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if i > 0, isWordChar(chars[i - 1]) {
            while i > 0, isWordChar(chars[i - 1]) { i -= 1 }
        } else if i > 0 {
            i -= 1
        }
        return max(chars.count - i, before.isEmpty ? 0 : 1)
    }

    private func space(now: Date) {
        if isComposing {
            if let first = candidates.first {
                if let text = composition.select(first, engine: engine) { insert(text) }
            } else if composition.remaining.isEmpty {
                // 分几次选完、又把剩下的字母删光了:只剩已选的字,空格把它们上屏。
                insert(composition.commitRaw())
            }
            return
        }
        // 英文连按两下空格 = 句号 + 空格(系统键盘的习惯)。
        if language == .english, let last = lastSpace, now.timeIntervalSince(last) < 0.6,
           let before = document?.contextBeforeInput, before.hasSuffix(" "),
           let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
            deleteBackwardInDocument()
            insert(". ")
            lastSpace = nil
            return
        }
        insert(" ")
        lastSpace = now
        if page != .letters { page = .letters }
    }

    private func returnKey() {
        if isComposing {
            commitRaw()
        } else {
            insert("\n")
        }
    }

    /// 把整个组合按首选一路选完上屏。
    private func commitBest() {
        while isComposing {
            let list = engine.candidates(for: composition.remaining, context: context(), limit: 1).candidates
            guard let first = list.first else { insert(composition.commitRaw()); return }
            if let text = composition.select(first, engine: engine) { insert(text) }
        }
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let before = document?.contextBeforeInput ?? ""
        document?.insertText(text)
        expectedEcho = Self.anchor(before + text)
    }

    private func deleteBackwardInDocument() {
        let before = document?.contextBeforeInput ?? ""
        document?.deleteBackward()
        expectedEcho = Self.anchor(String(before.dropLast()))
    }

    /// 给重排器的上文:光标前最近的一截 + 这次已经选好的几段。
    private func context() -> String {
        String((document?.contextBeforeInput ?? "").suffix(24)) + composition.pieces.map(\.text).joined()
    }

    static func anchor(_ context: String?) -> String { String((context ?? "").suffix(48)) }

    private func refresh() {
        if isComposing, !composition.remaining.isEmpty {
            let result = engine.candidates(for: composition.remaining, context: context())
            candidates = result.candidates
            segmented = result.segmented
        } else {
            candidates = []
            segmented = ""
        }
        if !isComposing { compositionAnchor = nil }
        suggestions = []
        if language == .english, !isComposing, let completer {
            let word = Self.trailingWord(document?.contextBeforeInput ?? "")
            if word.count >= 1 { suggestions = Array(completer.completions(for: word).prefix(8)) }
        }
        updateAutoShift()
        onChange?()
    }

    /// 自动大写只动它自己给的那个 `.once`:用户亲手按过的、锁定的都不碰。
    private func updateAutoShift() {
        guard shift != .locked, !shiftOverridden else { return }
        let wants = language == .english && page == .letters && shouldAutoCapitalize()
        if wants, shift == .off {
            shift = .once
            shiftIsAuto = true
        } else if !wants, shiftIsAuto, shift == .once {
            shift = .off
            shiftIsAuto = false
        }
    }

    func shouldAutoCapitalize() -> Bool {
        let before = document?.contextBeforeInput ?? ""
        switch autocapitalization {
        case .none: return false
        case .allCharacters: return true
        case .words: return before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || before.last == "\n" { return true }
            guard before.last == " " else { return false }
            return trimmed.last.map { Punctuation.sentenceEnders.contains($0) } ?? false
        }
    }

    static func trailingWord(_ s: String) -> String {
        String(s.reversed().prefix { $0.isLetter && $0.isASCII }.reversed())
    }
}
