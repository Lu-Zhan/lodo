import Foundation

/// 模糊音开关(设置里可选,默认全关)。
public struct FuzzyOptions: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let zZh = FuzzyOptions(rawValue: 1 << 0)
    public static let cCh = FuzzyOptions(rawValue: 1 << 1)
    public static let sSh = FuzzyOptions(rawValue: 1 << 2)
    public static let nL = FuzzyOptions(rawValue: 1 << 3)
    public static let inIng = FuzzyOptions(rawValue: 1 << 4)
    public static let enEng = FuzzyOptions(rawValue: 1 << 5)
    public static let anAng = FuzzyOptions(rawValue: 1 << 6)
}

/// 输入串上的一段:从 `start` 到 `end`(不含),可以读成 `ids` 里任何一个音节。
struct Token {
    enum Kind { case full, abbreviation, partial, fuzzy, corrected }
    let end: Int
    let ids: [UInt16]
    let kind: Kind
    var penalty: Int {
        switch kind {
        case .full: 0
        case .abbreviation: Costs.abbreviation
        case .partial: Costs.partial
        case .fuzzy: Costs.fuzzy
        case .corrected: Costs.correction
        }
    }
}

/// 代价单位同词库:-ln(p) × 100。数值在 `IMEEvalTests` 上调过,改了要重跑评测。
enum Costs {
    static let abbreviation = 350
    static let partial = 250
    static let correction = 450
    static let fuzzy = 200
    /// 认不出的字母:原样当一个"字",保证任何输入都能拼出整句。
    static let unknownLetter = 3000
    /// 每多一个词的拼装惩罚:让整键词典命中优先于两个高频字的拼接。
    static let perWord = 300
}

/// 把输入串切成 token 图。
struct Syllabifier {
    let lexicon: Lexicon
    let fuzzy: FuzzyOptions
    /// 每个音节的所有真前缀(含声母简拼)→ 以它开头且更长的音节。
    private let prefixes: [String: [UInt16]]
    /// 常见错拼(ign → ing 一类)与模糊音:输入串 → (音节, 是否为模糊音)。
    private let alternates: [String: [(UInt16, Bool)]]

    static let initials: Set<String> = [
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
        "r", "z", "c", "s", "y", "w", "zh", "ch", "sh",
    ]

    init(lexicon: Lexicon, fuzzy: FuzzyOptions = []) {
        self.lexicon = lexicon
        self.fuzzy = fuzzy
        var prefixes: [String: [UInt16]] = [:]
        for (i, s) in lexicon.syllables.enumerated() {
            for n in 1..<s.count { prefixes[String(s.prefix(n)), default: []].append(UInt16(i)) }
        }
        self.prefixes = prefixes

        var alternates: [String: [(UInt16, Bool)]] = [:]
        let index = lexicon.syllableIndex
        for (s, id) in index {
            // 韵尾 ng 打成 gn:xign、zhagn。
            if s.hasSuffix("ng"), s.count >= 3 {
                let typo = String(s.dropLast(2)) + "gn"
                if index[typo] == nil { alternates[typo, default: []].append((id, false)) }
            }
            for variant in Self.fuzzyVariants(of: s, options: fuzzy) where variant != s && index[variant] != nil {
                alternates[variant, default: []].append((id, true))
            }
        }
        self.alternates = alternates
    }

    /// 音节 s 在开着的模糊音下还会被打成哪些拼写。
    static func fuzzyVariants(of s: String, options: FuzzyOptions) -> [String] {
        var out = [s]
        func swapInitial(_ a: String, _ b: String) {
            out += out.compactMap { v in
                if v.hasPrefix(b) { return a + v.dropFirst(b.count) }
                if v.hasPrefix(a) && !v.hasPrefix(b) { return b + v.dropFirst(a.count) }
                return nil
            }
        }
        func swapFinal(_ a: String, _ b: String) {
            out += out.compactMap { v in
                if v.hasSuffix(b) { return v.dropLast(b.count) + a }
                if v.hasSuffix(a) { return v.dropLast(a.count) + b }
                return nil
            }
        }
        if options.contains(.zZh) { swapInitial("z", "zh") }
        if options.contains(.cCh) { swapInitial("c", "ch") }
        if options.contains(.sSh) { swapInitial("s", "sh") }
        if options.contains(.nL) {
            out += out.compactMap { v in
                if v.hasPrefix("n") { return "l" + v.dropFirst() }
                if v.hasPrefix("l") { return "n" + v.dropFirst() }
                return nil
            }
        }
        if options.contains(.inIng) { swapFinal("in", "ing") }
        if options.contains(.enEng) { swapFinal("en", "eng") }
        if options.contains(.anAng) { swapFinal("an", "ang") }
        return Array(Set(out))
    }

    /// `tokens[i]` = 从第 i 个字符开始的所有 token。`'` 处为空。
    func tokens(_ raw: [Character]) -> [[Token]] {
        let n = raw.count
        var out = Array(repeating: [Token](), count: n)
        for i in 0..<n where raw[i] != "'" {
            var j = i
            var piece = ""
            while j < n, raw[j] != "'", j - i < 6 {
                piece.append(raw[j])
                j += 1
                let atEnd = j == n || raw[j] == "'"
                if let id = lexicon.syllableIndex[piece] {
                    out[i].append(Token(end: j, ids: [id], kind: .full))
                }
                if let alt = alternates[piece] {
                    let fuzzyIDs = alt.filter(\.1).map(\.0), typoIDs = alt.filter { !$0.1 }.map(\.0)
                    if !fuzzyIDs.isEmpty { out[i].append(Token(end: j, ids: fuzzyIDs, kind: .fuzzy)) }
                    if !typoIDs.isEmpty { out[i].append(Token(end: j, ids: typoIDs, kind: .corrected)) }
                }
                if let longer = prefixes[piece] {
                    if Self.initials.contains(piece) && lexicon.syllableIndex[piece] == nil {
                        out[i].append(Token(end: j, ids: longer, kind: .abbreviation))
                    } else if atEnd {
                        out[i].append(Token(end: j, ids: longer, kind: .partial))
                    }
                }
            }
        }
        return out
    }
}
