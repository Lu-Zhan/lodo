import Foundation

/// 候选栏里的一条。
public struct Candidate: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// 用户上屏过的词或整句。
        case user
        /// 词典整键命中(一个词吃满整个键)。
        case dictionary
        /// 词图上多个词拼出来的整句。
        case assembled
        /// 只吃掉键的开头一截,选了之后剩下的接着拼。
        case prefix
    }

    public let text: String
    public let source: Source
    /// 选中后吃掉输入串的多少个字符(含跟在后面的 `'`)。
    public let consumed: Int
    /// 这条候选的音节编号,学习用。
    public let syllableIDs: [UInt16]
    /// 经过纠错或模糊音:那它的词频是"用户想打的词"的证据,不是"用户敲的那串字母"的证据。
    public let corrected: Bool

    public var answersKey: Bool { source != .prefix }
    /// 用户词同样算:上游把 UserDatabase 也列在 `DICTIONARY_SOURCES` 里,用户亲手选过的不让模型改。
    public var trustedDictionaryHit: Bool { (source == .dictionary || source == .user) && !corrected }
}

/// 词图上的一条边:输入串 [start, end) 读成一个词。
struct Edge {
    let start: Int
    let end: Int
    let text: String
    let cost: Int
    let ids: [UInt16]
    /// 词内每个音节的结束位置,用来画「zhong'guo」这样的分段。
    let cuts: [Int]
    let corrected: Bool
    let fromUser: Bool
}

/// 拼音引擎:无状态的查询(`candidates(for:)`)+ 一个组合态(`Composition`)。
public final class PinyinEngine: @unchecked Sendable {
    public let lexicon: Lexicon
    public var userDictionary: UserDictionary
    public var personalDictionary: PersonalDictionary?
    public var reranker: Reranker?
    public var fuzzy: FuzzyOptions { didSet { rebuildSyllabifier() } }
    public var correctionEnabled: Bool { didSet { rebuildSyllabifier() } }
    private var syllabifier: Syllabifier

    static let maxWordSyllables = 16
    /// 词图解码保留的整句条数。
    static let beam = 8

    public init(lexicon: Lexicon, userDictionary: UserDictionary = UserDictionary(),
                fuzzy: FuzzyOptions = [], correctionEnabled: Bool = true, reranker: Reranker? = nil) {
        self.lexicon = lexicon
        self.userDictionary = userDictionary
        self.fuzzy = fuzzy
        self.correctionEnabled = correctionEnabled
        self.reranker = reranker
        self.syllabifier = Syllabifier(lexicon: lexicon, fuzzy: fuzzy, correctionEnabled: correctionEnabled)
    }

    private func rebuildSyllabifier() {
        syllabifier = Syllabifier(lexicon: lexicon, fuzzy: fuzzy, correctionEnabled: correctionEnabled)
    }

    // MARK: - 查询

    public struct Result: Sendable {
        public let candidates: [Candidate]
        /// 当前最佳切分,如 "zhong'guo'ren"。
        public let segmented: String
    }

    /// `input` 只含小写字母和 `'`;`context` 是光标前的文字,给重排器用。
    /// `rerank: false` 只要切分(预编辑)时用,省一次模型调用。
    public func candidates(for input: String, context: String = "", limit: Int = 60,
                           rerank: Bool = true, now: Date = Date()) -> Result {
        let raw = Array(input.lowercased())
        let n = raw.count
        guard n > 0 else { return Result(candidates: [], segmented: "") }
        let tokens = syllabifier.tokens(raw)
        func skip(_ p: Int) -> Int { var p = p; while p < n, raw[p] == "'" { p += 1 }; return p }

        // 只从走得到的位置出发找边。
        let start0 = skip(0)
        var edgesFrom = [[Edge]?](repeating: nil, count: n + 1)
        var best = [[(cost: Int, edge: Edge?, prev: Int)]](repeating: [], count: n + 1)
        best[start0] = [(0, nil, -1)]
        for p in start0..<n where !best[p].isEmpty {
            let edges = edges(from: p, raw: raw, tokens: tokens, perNode: p == start0 ? 40 : 4, now: now)
            edgesFrom[p] = edges
            for e in Self.pruned(edges, perEnd: 6) {
                let land = skip(e.end)
                for (rank, node) in best[p].enumerated() {
                    let cost = node.cost + e.cost + Costs.perWord
                    Self.insert(&best[land], (cost, e, rank), limit: Self.beam)
                }
            }
        }

        // 回溯出整句。
        func path(_ node: Int, _ rank: Int) -> [Edge] {
            var out: [Edge] = []
            var pos = node, r = rank
            while let e = best[pos][r].edge {
                out.append(e)
                r = best[pos][r].prev
                pos = e.start
            }
            return out.reversed()
        }

        var list: [Candidate] = []
        var seen = Set<String>()
        func add(_ c: Candidate) { if seen.insert(c.text).inserted { list.append(c) } }

        let sentences = best[n].indices.map { path(n, $0) }
        let first = edgesFrom[start0] ?? []
        let fullKey = first.filter { skip($0.end) == n }.sorted { $0.cost < $1.cost }
        let prefixes = first.filter { skip($0.end) < n }
            .sorted { ($0.end, -$0.cost) > ($1.end, -$1.cost) }

        func candidate(_ edges: [Edge]) -> Candidate {
            let text = edges.map(\.text).joined()
            let source: Candidate.Source = edges.count > 1 ? .assembled : (edges[0].fromUser ? .user : .dictionary)
            return Candidate(text: text, source: source, consumed: n, syllableIDs: edges.flatMap(\.ids),
                             corrected: edges.contains(where: \.corrected))
        }
        for s in sentences.prefix(3) where !s.isEmpty { add(candidate(s)) }
        for e in fullKey { add(candidate([e])) }
        for s in sentences.dropFirst(3) where !s.isEmpty { add(candidate(s)) }
        for e in prefixes {
            add(Candidate(text: e.text, source: .prefix, consumed: skip(e.end),
                          syllableIDs: e.ids, corrected: e.corrected))
            if list.count >= limit { break }
        }
        if rerank, let reranker, let top = list.first, !top.trustedDictionaryHit, !top.corrected {
            // 上游只比前 9 条整键候选;试过收窄到 3/5 条,救回的少了、弄坏的没少。
            // 词图已把可信的纠错放到首位时,模型容易又按高频偏好改回错词(nihaya → 你还要)。
            let pool = list.indices.filter { list[$0].answersKey }
            if pool.count > 1,
               let pick = reranker.best(context: context, candidates: pool.map {
                   RerankCandidate(text: list[$0].text, answersKey: true, trustedDictionaryHit: list[$0].trustedDictionaryHit)
               }), pool.indices.contains(pick), pool[pick] != 0 {
                let chosen = list.remove(at: pool[pick])
                list.insert(chosen, at: 0)
            }
        }

        var segmented = ""
        if raw.contains(where: { Syllabifier.nineKeyLetters[$0] != nil }) {
            // 九宫格:输入框里显示最可能的那串拼音(64426 → ni'hao),而不是数字;
            // 末音节没按完的只写按到的那几个字母。
            segmented = Self.spelling(of: sentences.first ?? [], raw: raw, lexicon: lexicon)
        } else {
            let cuts = Set((sentences.first ?? []).flatMap(\.cuts))
            for (i, ch) in raw.enumerated() {
                segmented.append(ch)
                if cuts.contains(i + 1), i + 1 < n, raw[i + 1] != "'", ch != "'" { segmented.append("'") }
            }
        }
        return Result(candidates: Array(list.prefix(limit)), segmented: segmented)
    }

    /// 一条整句路径按音节写成拼音:每个音节取它在输入里占的那几个字符那么长。
    static func spelling(of path: [Edge], raw: [Character], lexicon: Lexicon) -> String {
        var parts: [String] = []
        for e in path {
            var start = e.start
            for (k, cut) in e.cuts.enumerated() {
                while start < raw.count, raw[start] == "'" { start += 1 }
                let typed = max(cut - start, 1)
                if k < e.ids.count {
                    parts.append(String(lexicon.syllables[Int(e.ids[k])].prefix(typed)))
                } else {
                    parts.append(String(raw[start..<min(cut, raw.count)]))
                }
                start = cut
            }
        }
        return parts.joined(separator: "'")
    }

    /// 九宫格左边那列:剩下的数字开头能读成哪些拼音,常用的在前。
    public func nineKeySyllables(for input: String) -> [(syllable: String, length: Int)] {
        // 第一段还没定的数字(前面选定的拼音跳过)。
        let digits = String(input.drop { Syllabifier.nineKeyLetters[$0] == nil }.prefix { $0 != "'" })
        return syllabifier.nineKeySyllables(digits) { [lexicon] id in
            // 拿这个音节最常用的单字的代价当排序依据。
            let r = lexicon.narrow(lexicon.all, depth: 0, id: id)
            var best = Int.max, k = r.lowerBound
            while k < r.upperBound, lexicon.length(k) == 1 { best = min(best, lexicon.cost(k)); k += 1 }
            return best
        }
    }

    private static func insert(_ list: inout [(cost: Int, edge: Edge?, prev: Int)], _ item: (cost: Int, edge: Edge?, prev: Int), limit: Int) {
        if list.count >= limit, let last = list.last, last.cost <= item.cost { return }
        let i = list.firstIndex { $0.cost > item.cost } ?? list.count
        list.insert(item, at: i)
        if list.count > limit { list.removeLast() }
    }

    /// 每个落点只留最便宜的几条,解码不必在几百个同音字里打转。
    private static func pruned(_ edges: [Edge], perEnd: Int) -> [Edge] {
        Dictionary(grouping: edges, by: \.end).values.flatMap { $0.sorted { $0.cost < $1.cost }.prefix(perEnd) }
    }

    /// 从 `start` 出发,在词库与用户词里找所有能接上的词。
    private func edges(from start: Int, raw: [Character], tokens: [[Token]], perNode: Int, now: Date) -> [Edge] {
        let n = raw.count
        var out: [Edge] = []
        var ids: [UInt16] = []
        var cuts: [Int] = []
        func skip(_ p: Int) -> Int { var p = p; while p < n, raw[p] == "'" { p += 1 }; return p }

        func dfs(_ pos: Int, _ range: Range<Int>, _ penalty: Int, _ corrected: Bool) {
            let depth = ids.count
            for token in tokens[pos] {
                let pen = penalty + token.penalty
                let corr = corrected || token.kind == .corrected || token.kind == .fuzzy
                for id in token.ids {
                    let r = range.isEmpty ? range : lexicon.narrow(range, depth: depth, id: id)
                    ids.append(id)
                    cuts.append(token.end)
                    defer { ids.removeLast(); cuts.removeLast() }
                    var k = r.lowerBound, taken = 0
                    while k < r.upperBound, lexicon.length(k) == depth + 1 {
                        if taken < perNode {
                            out.append(Edge(start: start, end: token.end, text: lexicon.word(k), cost: lexicon.cost(k) + pen,
                                            ids: ids, cuts: cuts, corrected: corr, fromUser: false))
                            taken += 1
                        }
                        k += 1
                    }
                    if !userDictionary.isEmpty {
                        for (word, cost) in userDictionary.words(for: ids, now: now) {
                            out.append(Edge(start: start, end: token.end, text: word, cost: cost + pen,
                                            ids: ids, cuts: cuts, corrected: corr, fromUser: true))
                        }
                    }
                    if let personalDictionary {
                        for (word, cost) in personalDictionary.words(for: ids) {
                            out.append(Edge(start: start, end: token.end, text: word, cost: cost + pen,
                                            ids: ids, cuts: cuts, corrected: corr, fromUser: true))
                        }
                    }
                    let next = skip(token.end)
                    let deeper = k < r.upperBound || (!userDictionary.isEmpty && userDictionary.hasPhrase(withPrefix: ids))
                        || (personalDictionary?.hasPhrase(withPrefix: ids) == true)
                    if depth + 1 < Self.maxWordSyllables, next < n, deeper {
                        dfs(next, k..<r.upperBound, pen, corr)
                    }
                }
            }
        }
        dfs(start, lexicon.all, 0, false)

        // 认不出的字母原样保留,任何输入都拼得出整句。
        if !out.contains(where: { $0.start == start }) {
            out.append(Edge(start: start, end: start + 1, text: String(raw[start]), cost: Costs.unknownLetter,
                            ids: [], cuts: [start + 1], corrected: false, fromUser: false))
        }
        return out
    }
}
