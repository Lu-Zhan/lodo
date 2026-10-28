import Foundation

/// 一次输入的组合态:可以分几次选(先选「中国」,剩下的接着拼),拼完一次性上屏。
public struct Composition: Sendable {
    public struct Piece: Sendable {
        public let text: String
        public let ids: [UInt16]
        /// 这一段对应的原始输入,退格撤回选择时还原用。
        public let raw: String
        public let source: Candidate.Source
    }

    /// 还没选的那截输入。九宫格左栏选定的拼音用**大写**存(`NI'426`):解码按它只认这个音节
    /// (单个声母就是以它开头的音节),不补全、不纠错——不能从「串里还有没有数字」去猜哪些字母是选定的。
    /// 打字只会进小写,所以大写就是选定的标记;显示和原样上屏用 `display`。
    public private(set) var remaining = ""

    /// `remaining` 去掉选定标记,给输入框显示、原样上屏用。
    public var display: String { remaining.lowercased() }
    /// 已经选好、还没上屏的几段。
    public private(set) var pieces: [Piece] = []

    public init() {}

    public var isEmpty: Bool { remaining.isEmpty && pieces.isEmpty }

    public mutating func insert(_ letter: Character) {
        // 九宫格按的是 2–9。
        guard letter.isASCII, letter.isLetter || letter == "'" || Syllabifier.nineKeyLetters[letter] != nil else { return }
        // 开头不能是分隔符,也不能连着两个。
        if letter == "'", remaining.isEmpty || remaining.last == "'" { return }
        remaining.append(Character(letter.lowercased()))
    }

    /// 退格:先删字母;字母删完了撤回最后一次选择。
    /// 末尾是左栏选定的拼音时整段退回成数字(NI'HAO → NI'426),再按才删数字,同系统九宫格。
    public mutating func backspace() {
        if let last = remaining.last, last.isUppercase {
            let start = remaining.lastIndex { !$0.isUppercase }.map { remaining.index(after: $0) } ?? remaining.startIndex
            let code = Syllabifier.nineKeyCode(remaining[start...].lowercased())
            remaining = String(remaining[..<start]) + code
        } else if !remaining.isEmpty {
            remaining.removeLast()
        } else if let last = pieces.popLast() {
            remaining = last.raw
        }
    }

    /// 九宫格:还没定的那串数字里,开头 `count` 个定成 `syllable` 这个拼音(左边那列选了「ni」)。
    /// 前面已经定过的拼音不动(ni'426 再选 hao → ni'hao)。
    public mutating func fixSpelling(_ syllable: String, consuming count: Int) {
        guard let start = remaining.firstIndex(where: { Syllabifier.nineKeyLetters[$0] != nil }) else { return }
        let end = remaining.index(start, offsetBy: min(count, remaining.distance(from: start, to: remaining.endIndex)))
        let rest = remaining[end...]
        remaining = remaining[..<start] + syllable.uppercased() + (rest.isEmpty || rest.first == "'" ? "" : "'") + rest
    }

    /// 剩下的里面还有没按成拼音的数字(九宫格)。
    public var hasNineKeyDigits: Bool { remaining.contains { Syllabifier.nineKeyLetters[$0] != nil } }

    public mutating func clear() {
        remaining = ""
        pieces = []
    }

    /// 选一条候选。整个输入都选完了返回要上屏的文字,否则 nil(接着选剩下的)。
    public mutating func select(_ candidate: Candidate, engine: PinyinEngine) -> String? {
        let consumed = min(candidate.consumed, remaining.count)
        let raw = String(remaining.prefix(consumed))
        remaining.removeFirst(consumed)
        pieces.append(Piece(text: candidate.text, ids: candidate.syllableIDs, raw: raw, source: candidate.source))
        guard remaining.isEmpty else { return nil }
        return finish(engine: engine)
    }

    /// 按回车:已选的字 + 剩下的原始字母上屏(打英文单词时用)。
    public mutating func commitRaw() -> String {
        let text = pieces.map(\.text).joined() + display
        clear()
        return text
    }

    /// 预编辑文字:已选的字 + 剩下那截的最佳切分。
    public func preedit(engine: PinyinEngine) -> String {
        let head = pieces.map(\.text).joined()
        guard !remaining.isEmpty else { return head }
        return head + engine.candidates(for: remaining, limit: 1, rerank: false).segmented
    }

    private mutating func finish(engine: PinyinEngine) -> String {
        let text = pieces.map(\.text).joined()
        // 拼出来的整句和分几次选的组合都学成一个整体,下次整串直接出。
        // 单独一段的词典词也学:用户选了它就是比当时排前面的更想要它。
        let ids = pieces.flatMap(\.ids)
        // 主 app 里关了「记住常用词」:照常上屏,不学。
        guard engine.learnsWords else { pieces = []; return text }
        if !ids.isEmpty, pieces.allSatisfy({ !$0.ids.isEmpty }) {
            engine.userDictionary.learn(text, ids: ids)
        }
        if pieces.count > 1 {
            for p in pieces where p.text.count > 1 && !p.ids.isEmpty { engine.userDictionary.learn(p.text, ids: p.ids) }
        }
        pieces = []
        return text
    }
}
