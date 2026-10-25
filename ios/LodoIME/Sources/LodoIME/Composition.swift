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

    /// 还没选的那截输入。
    public private(set) var remaining = ""
    /// 已经选好、还没上屏的几段。
    public private(set) var pieces: [Piece] = []

    public init() {}

    public var isEmpty: Bool { remaining.isEmpty && pieces.isEmpty }

    public mutating func insert(_ letter: Character) {
        guard letter.isASCII, letter.isLetter || letter == "'" else { return }
        // 开头不能是分隔符,也不能连着两个。
        if letter == "'", remaining.isEmpty || remaining.last == "'" { return }
        remaining.append(Character(letter.lowercased()))
    }

    /// 退格:先删字母;字母删完了撤回最后一次选择。
    public mutating func backspace() {
        if !remaining.isEmpty {
            remaining.removeLast()
        } else if let last = pieces.popLast() {
            remaining = last.raw
        }
    }

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
        let text = pieces.map(\.text).joined() + remaining
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
