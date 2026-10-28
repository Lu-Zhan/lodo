import Foundation
import LodoIME

/// 键盘写字的对象:扩展里是 `textDocumentProxy`,测试里是假的。
public protocol TextDocument: AnyObject {
    var contextBeforeInput: String? { get }
    func insertText(_ text: String)
    func deleteBackward()
    /// 能不能把正在拼的拼音写成宿主里的「标记文字」(带下划线、还没确认的那段,系统拼音键盘就是这样)。
    var supportsMarkedText: Bool { get }
    func setMarkedText(_ text: String)
    /// 把标记文字原样确认下来。
    func unmarkText()
}

public extension TextDocument {
    var supportsMarkedText: Bool { false }
    func setMarkedText(_ text: String) {}
    func unmarkText() {}
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
    /// 有它就在后台解码(键盘里);没有就当场同步解(单测、简单宿主)。
    public var decoder: BackgroundDecoder?

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
    /// 学进了用户词(整段选完上屏):键盘据此安排落盘。上屏可能发生在后台结果回来时,不能靠按键前后的组合状态推断。
    public var onLearn: (() -> Void)?

    private var lastShiftTap: Date?
    private var lastSpace: Date?
    /// 当前的 `.once` 是自动大写给的(不是用户按的):挪到句中要撤掉。
    private var shiftIsAuto = false
    /// 用户在这个位置亲手按过 shift:自动大写别再改它,直到光标前的文字变了。
    private var shiftOverridden = false
    /// 开始拼音那一刻光标前的文字。拼音不写进宿主,所以宿主的文字变了只可能是外部改动;
    /// 没变就是我们自己上一次上屏迟到的 `textDidChange`,不能清掉正在拼的字。
    private var compositionAnchor: String?
    /// 开始拼音那一刻光标前的完整文字(不含标记文字):给重排器当上文、算上屏后的回声。
    private var compositionBase: String?
    /// 现在写在宿主里的标记文字(拼音);空 = 没写。
    private var marked = ""
    /// 这一轮写过的标记文字:宿主的回调可能慢一拍,光标前是「开头 + 其中任何一版」都算自己的回声。
    private var markedHistory: [String] = []
    /// 我们最后一次写宿主(上屏、删除)之后,光标前应有的文字。之后来的 `textDidChange` 是不是它的回声,
    /// 就看光标前的文字是不是正好是它(宿主的 context 可能慢一拍,所以不能只比开始拼音时的锚点)。
    private var expectedEcho: String?
    /// 上一次解码的切分(zhong'guo),预编辑直接用它,不为了显示再解一遍。
    private var segmented = ""
    /// `candidates` 是对哪一串拼音解出来的:拼音后按标点时直接上屏屏幕上那个首选,不再解一遍。
    private var candidatesKey: String?
    /// 这一次事件里光标前的文字。`contextBeforeInput` 要跨进程问宿主,一次按键里只问一次;
    /// 自己写进去的字按应有的样子续上。每个事件开头清空(宿主可能在两次事件之间变了)。
    private var cachedContext: String??
    /// 后台正在解哪一串(同一时间只发一个,回来时拼音又变了就接着解最新的,不排长队)。
    private var decodingKey: String?
    private enum QueuedInput {
        case action(KeyAction)
        case candidate(Candidate, String)
        case rawLetters(String?)
        case fixSpelling(String, Int)
    }
    /// 等基础候选时仍收按键;结果到达后按原顺序处理,不在触摸回调里同步等词图。
    private var commitKey: String?
    private var queuedInputs: [QueuedInput] = []
    /// 组合的「轮次」:上屏、清空、选了一段、换写字对象都加一。后台结果只认发请求时那一轮——
    /// 光比拼音不够:上屏后再打同样的字母,上文、已选片段、用户词都变了,上一轮的候选不再适用。
    private var compositionGeneration = 0
    static let doubleTap: TimeInterval = 0.35

    public init(engine: PinyinEngine, language: InputLanguage = .chinese) {
        self.engine = engine
        self.language = language
    }

    public var isComposing: Bool { !composition.isEmpty }

    /// 候选栏上方那一行:已选的字 + 剩下拼音的切分(zhong'guo)。
    public var preedit: String {
        // 候选还没跟上最新的拼音时,剩下那截先原样显示(旧的切分对不上新字母)。
        composition.pieces.map(\.text).joined() + (candidatesAreCurrent ? segmented : composition.remaining)
    }

    /// 屏幕上的候选是不是对当前这串拼音解出来的(后台解码时可能慢一拍)。
    public var candidatesAreCurrent: Bool { candidatesKey == composition.remaining }

    /// 个性词库换版后,正在显示的候选失效;下一轮解码使用新快照。
    public func personalDictionaryChanged() {
        candidatesKey = nil
        compositionGeneration += 1
        if isComposing { requestDecode() }
    }

    // MARK: - 按键

    public func handle(_ action: KeyAction, now: Date = Date()) {
        if commitKey != nil {
            queuedInputs.append(.action(action))
            return
        }
        if needsCandidateBefore(action), let decoder {
            let key = composition.remaining
            commitKey = key
            queuedInputs.append(.action(action))
            decoder.decodeForCommit(key, context: context()) { [weak self] result in
                guard let self, self.commitKey == key else { return }
                self.commitKey = nil
                let queued = self.queuedInputs
                self.queuedInputs = []
                if self.composition.remaining == key, !self.candidatesAreCurrent {
                    self.candidates = result.candidates
                    self.segmented = result.segmented
                    self.candidatesKey = key
                }
                // 拼音在等的时候变了(九宫格选了拼音)也照样按顺序重放:排着的空格、标点会再等一次最新的候选,不能丢。
                self.replay(queued)
            }
            return
        }
        cachedContext = nil
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
        case .clearComposition:
            composition.clear()
        case .nineKeyOne:
            if isComposing { separator() } else { insert("@") }
        }
        if action != .space { lastSpace = nil }
        refresh()
    }

    private func needsCandidateBefore(_ action: KeyAction) -> Bool {
        guard isComposing, !composition.remaining.isEmpty, !candidatesAreCurrent else { return false }
        switch action {
        case .space, .text: return true
        case .letter: return shift != .off
        default: return false
        }
    }

    /// 选候选栏里的第 i 条。
    public func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        select(candidates[index], decodedFor: candidatesKey ?? composition.remaining)
    }

    /// 候选是对哪一串拼音解出来的(界面上那颗按钮记着的)。
    public var candidatesDecodedFor: String? { candidatesKey }

    /// 选一条候选。`key` 是它解出来时的拼音:屏幕上的候选可能比最新拼音慢一拍(后台解码、或按着候选时
    /// 候选栏没换),点的是什么就上什么——只多打了字母时它照样成立,吃掉它那几个字母、剩下的接着拼;
    /// 删过字母就对不上了,按文字在最新结果里找,找不到就不选(只刷新候选)。
    public func select(_ candidate: Candidate, decodedFor key: String) {
        if commitKey != nil {
            queuedInputs.append(.candidate(candidate, key))
            return
        }
        guard isComposing else { return }
        cachedContext = nil
        var picked = candidate
        if !composition.remaining.hasPrefix(key) {
            if !candidatesAreCurrent { requestDecode(); return }
            guard let same = candidates.first(where: { $0.text == candidate.text }) else { return refresh() }
            picked = same
        }
        if let text = select(picked) { insert(text) }
        refresh()
    }

    /// 选一条英文补全:替换掉光标前那半个单词,后面补个空格。
    public func selectSuggestion(_ word: String) {
        cachedContext = nil
        let partial = Self.trailingWord(contextBefore ?? "")
        for _ in partial { deleteBackwardInDocument() }
        insert(word + " ")
        refresh()
    }

    /// 宿主的文字或光标变了(`textDidChange`):只有光标前的文字确实和开始拼音时不一样
    /// (用户点到别处、宿主自己改了内容)才丢掉没上屏的拼音;然后重算自动大写。
    public func documentChanged() {
        cachedContext = nil
        let current = Self.anchor(contextBefore)
        // 只认「光标前正好是我们最后一次编辑后该有的样子」,而且每次回调都把它作废——
        // 不管这次是不是回声,留着旧值以后挪回原处会被误认(codex 复核指出)。
        // 光看后缀也不行:前文里本来就有同样的字时,把光标挪过去也会对上。
        let isEcho = current == expectedEcho
        expectedEcho = nil
        if isComposing, let anchor = compositionAnchor, anchor != current {
            if usesMarkedText, isMarkedEcho(current) {
                // 我们写标记文字(拼音)引起的回调:不动
            } else if isEcho {
                compositionAnchor = current // 自己上一次编辑的回声:跟上宿主,别清
            } else {
                // 用户挪了光标、换了输入框、宿主自己改了内容:丢掉没上屏的拼音。
                // 宿主那边的标记文字归宿主处理(挪光标时它会自己确认掉),这边只是不再认它。
                composition.clear()
                commitKey = nil
                queuedInputs = []
                compositionAnchor = nil
                marked = ""
            }
        }
        shiftOverridden = false
        // 还在拼、拼音没被清掉:候选不会变(拼音不写进宿主),不必重新解码,只重算自动大写。
        if isComposing, candidatesKey == composition.remaining {
            updateAutoShift()
            cachedContext = nil
            onChange?()
            return
        }
        refresh()
    }

    /// 宿主换了输入框(`documentIdentifier` 变了):上一框没上屏的拼音作废,不能带进新框——
    /// 新框光标前的文字可能碰巧和开始拼音时一样(都是空的),`documentChanged` 的回声判断分不出来。
    public func abandonComposition() {
        commitKey = nil
        queuedInputs = []
        composition.clear()
        compositionAnchor = nil
        expectedEcho = nil
        marked = ""
        markedHistory = []
        cachedContext = nil
        refresh()
    }

    /// 换写字的对象(打开/关掉 lodo 面板时):先把正在拼的字母原样留在原来那边。
    public func switchDocument(to document: TextDocument) {
        commitRaw()
        self.document = document
        cachedContext = nil
        expectedEcho = nil // 换了写字的对象,上一边的回声不作数
        refresh()
    }

    /// 候选栏里「原样字母」那一项显示的文字,也正是点了之后上屏的文字:已选的字 + 剩下的字母(不带分隔符)。
    public var rawLetters: String {
        composition.pieces.map(\.text).joined() + composition.remaining.replacingOccurrences(of: "'", with: "")
    }

    /// 点了「原样字母」:按显示的那样上屏。`expected` 是那颗按钮上写的字——按着它时另一指又打了字母、
    /// 候选栏没换,松手时对不上就不上屏(只刷新),免得上屏的和看到的不一样。
    public func commitRawLetters(expected: String? = nil) {
        if commitKey != nil {
            queuedInputs.append(.rawLetters(expected))
            return
        }
        guard isComposing else { return }
        cachedContext = nil
        if let expected, expected != rawLetters { return refresh() }
        let text = rawLetters
        composition.clear()
        insert(text)
        refresh()
    }

    /// 键盘收起前把正在拼的字母原样留下,不吞掉用户的输入。
    public func commitRaw() {
        flushPendingForDismissal()
        guard isComposing else { return }
        if composition.hasNineKeyDigits {
            // 九宫格按的是数字:原样上屏的是输入框里显示的那串拼音,不是数字。
            if !candidatesAreCurrent { decodeNow() }
            let text = composition.pieces.map(\.text).joined() + segmented.replacingOccurrences(of: "'", with: "")
            composition.clear()
            insert(text)
            return
        }
        insert(composition.commitRaw())
    }

    /// 收键盘/换宿主时不能留下尚未处理的按键;此处罕见路径允许同步补解。
    private func flushPendingForDismissal() {
        guard commitKey != nil else { return }
        commitKey = nil
        let queued = queuedInputs
        queuedInputs = []
        let background = decoder
        decoder = nil
        replay(queued)
        decoder = background
    }

    private func replay(_ queued: [QueuedInput]) {
        for input in queued {
            switch input {
            case .action(let action): handle(action)
            case .candidate(let candidate, let key): select(candidate, decodedFor: key)
            case .rawLetters(let expected): commitRawLetters(expected: expected)
            case .fixSpelling(let syllable, let length): fixSpelling(syllable, length: length)
            }
        }
    }

    /// 九宫格左边那列:剩下的数字开头能读成哪些拼音。
    public var nineKeySyllables: [(syllable: String, length: Int)] {
        guard composition.hasNineKeyDigits else { return [] }
        return engine.nineKeySyllables(for: composition.remaining)
    }

    /// 在左边那列选了一个拼音:开头那几个数字定成它。
    public func fixSpelling(_ syllable: String, length: Int) {
        if commitKey != nil {
            queuedInputs.append(.fixSpelling(syllable, length))
            return
        }
        guard isComposing else { return }
        cachedContext = nil
        // 按着左栏时列表可能已经换了:只认对当前开头那几个数字仍然成立的拼音。
        guard nineKeySyllables.contains(where: { $0.syllable == syllable && $0.length == length }) else { return refresh() }
        composition.fixSpelling(syllable, consuming: length)
        refresh()
    }

    // MARK: -

    private func typeLetter(_ c: Character) {
        let upper = shift != .off
        if shift == .once { shift = .off; shiftIsAuto = false }
        if language == .chinese && !upper {
            if !isComposing {
                let before = contextBefore
                compositionAnchor = Self.anchor(before)
                compositionBase = before ?? ""
                markedHistory = []
            }
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
        insert(Punctuation.resolveQuote(t, before: contextBefore ?? ""))
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
        guard let before = contextBefore, !before.isEmpty else { return deleteBackwardInDocument() }
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
            if !candidatesAreCurrent { decodeNow() }
            if let first = candidates.first {
                if let text = select(first) { insert(text) }
            } else if composition.remaining.isEmpty {
                // 分几次选完、又把剩下的字母删光了:只剩已选的字,空格把它们上屏。
                insert(composition.commitRaw())
            }
            return
        }
        // 英文连按两下空格 = 句号 + 空格(系统键盘的习惯)。
        if language == .english, let last = lastSpace, now.timeIntervalSince(last) < 0.6,
           let before = contextBefore, before.hasSuffix(" "),
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
            // 第一段直接用屏幕上的首选(用户看到的就是它),选完还剩拼音才接着解。
            let list = candidatesAreCurrent && !candidates.isEmpty
                ? candidates
                : decodeSync(composition.remaining, limit: 1).candidates
            candidatesKey = nil
            guard let first = list.first else { insert(composition.commitRaw()); return }
            if let text = select(first) { insert(text) }
        }
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let before: String
        if !marked.isEmpty {
            // 拼音写在宿主里:用上屏的字换掉那段标记文字再确认,不是在它后面接着插。
            before = compositionBase ?? ""
            document?.setMarkedText(text)
            document?.unmarkText()
            marked = ""
        } else {
            before = contextBefore ?? ""
            document?.insertText(text)
        }
        expectedEcho = Self.anchor(before + text)
        cachedContext = .some(before + text)
    }

    private var usesMarkedText: Bool { document?.supportsMarkedText == true }

    /// 宿主里应该写着的拼音:已选的字 + 剩下那截的切分,音节之间用空格(同系统:「ni hao」)。
    public var markedDisplay: String {
        composition.pieces.map(\.text).joined()
            + (candidatesAreCurrent ? segmented : composition.remaining).replacingOccurrences(of: "'", with: " ")
    }

    /// 拼音写在输入框里时,候选栏上面就不用再放一行拼音了。
    public var showsPreeditInBar: Bool { !usesMarkedText }

    /// 把宿主里的标记文字对齐到当前的组合(打字母、删字母、解码回来换了切分、组合结束)。
    private func syncMarkedText() {
        guard usesMarkedText else { return }
        let want = isComposing ? markedDisplay : ""
        guard want != marked else { return }
        document?.setMarkedText(want)
        if want.isEmpty {
            document?.unmarkText() // 删光了:把空的标记确认掉,宿主里不留东西
        } else {
            markedHistory.append(want)
            if markedHistory.count > 32 { markedHistory.removeFirst() }
        }
        marked = want
        cachedContext = nil
    }

    private func isMarkedEcho(_ current: String) -> Bool {
        let base = compositionBase ?? ""
        return current == Self.anchor(base) || markedHistory.contains { current == Self.anchor(base + $0) }
    }

    private func deleteBackwardInDocument() {
        let before = contextBefore ?? ""
        document?.deleteBackward()
        expectedEcho = Self.anchor(String(before.dropLast()))
        cachedContext = .some(String(before.dropLast()))
    }

    /// 光标前的文字,一次事件里只问宿主一次(见 `cachedContext`)。
    private var contextBefore: String? {
        if let cached = cachedContext { return cached }
        let value = document?.contextBeforeInput
        cachedContext = .some(value)
        return value
    }

    /// 给重排器的上文:光标前最近的一截 + 这次已经选好的几段。
    private func context() -> String {
        // 拼的时候用开始拼音那一刻的上文:宿主里光标前现在可能连着我们写进去的拼音。
        let before = isComposing ? (compositionBase ?? contextBefore) : contextBefore
        return String((before ?? "").suffix(24)) + composition.pieces.map(\.text).joined()
    }

    static func anchor(_ context: String?) -> String { String((context ?? "").suffix(48)) }

    /// 选一条候选;整段选完时学进用户词,并把新的用户词交给后台那份引擎。
    private func select(_ candidate: Candidate) -> String? {
        let text = composition.select(candidate, engine: engine)
        compositionGeneration += 1
        if text != nil {
            decoder?.setUserDictionary(engine.userDictionary)
            onLearn?()
        }
        return text
    }

    private func decodeSync(_ input: String, limit: Int = 60) -> PinyinEngine.Result {
        // 仅用于收键盘、九宫格原样确认和极少数分段上屏的兜底。
        // 不排进可能正在跑模型的后台队列,也不调用模型。
        return engine.candidates(for: input, context: context(), limit: limit, rerank: false)
    }

    /// 当场把候选解到最新(上屏那一下用)。
    private func decodeNow() {
        guard isComposing, !composition.remaining.isEmpty else { return }
        let result = decodeSync(composition.remaining)
        candidates = result.candidates
        segmented = result.segmented
        candidatesKey = composition.remaining
    }

    /// 后台解当前这串;已经有一个在解就等它回来再说(回来时发现拼音变了会接着解最新的)。
    private func requestDecode() {
        guard let decoder, decodingKey == nil else { return }
        let key = composition.remaining
        let generation = compositionGeneration
        decodingKey = key
        decoder.decode(key, context: context()) { [weak self] result, enriched in
            guard let self else { return }
            if !enriched, self.decodingKey == key { self.decodingKey = nil }
            guard self.isComposing, !self.composition.remaining.isEmpty else { return }
            if self.composition.remaining == key, self.compositionGeneration == generation {
                // 结果和屏幕上一样时也要把候选标回「是最新的」(换个人词库后会先作废),否则空格还会再等一次。
                let wasCurrent = self.candidatesAreCurrent
                self.candidatesKey = key
                guard !wasCurrent || self.candidates != result.candidates || self.segmented != result.segmented else { return }
                self.candidates = result.candidates
                self.segmented = result.segmented
                self.cachedContext = nil
                self.syncMarkedText() // 切分出来了:输入框里的「nihao」换成「ni hao」
                self.onChange?()
            } else if !enriched && !self.candidatesAreCurrent {
                self.requestDecode()
            }
        }
    }

    private func refresh() {
        if isComposing, !composition.remaining.isEmpty {
            if decoder == nil {
                let result = engine.candidates(for: composition.remaining, context: context())
                candidates = result.candidates
                segmented = result.segmented
                candidatesKey = composition.remaining
            } else if !candidatesAreCurrent {
                requestDecode() // 旧候选先留在屏幕上,解完再换,不闪
            }
        } else {
            candidates = []
            segmented = ""
            candidatesKey = nil
            compositionGeneration += 1 // 这一轮结束了(上屏、清空、换写字对象),还在路上的结果作废
        }
        syncMarkedText()
        if !isComposing { compositionAnchor = nil; compositionBase = nil }
        suggestions = []
        if language == .english, !isComposing, let completer {
            let word = Self.trailingWord(contextBefore ?? "")
            if word.count >= 1 { suggestions = Array(completer.completions(for: word).prefix(8)) }
        }
        updateAutoShift()
        cachedContext = nil // 事件结束:下一次再问宿主
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
        let before = contextBefore ?? ""
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
