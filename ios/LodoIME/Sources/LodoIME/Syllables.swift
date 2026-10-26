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
    // 未完成音节只在串尾补全;明确敲完的末音节应优先于凭词频补字母。
    static let partial = 650
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
    let correctionEnabled: Bool
    /// 每个音节的所有真前缀(含声母简拼)→ 以它开头且更长的音节。
    private let prefixes: [String: [UInt16]]
    /// 常见错拼(ign → ing 一类)与模糊音:输入串 → (音节, 是否为模糊音)。
    private let alternates: [String: [(UInt16, Bool)]]
    /// 漏敲一个元音时的候选。只预建音节索引,查询时不扫描整份词库。
    private let missingVowel: [String: [UInt16]]
    /// 九宫格:数字串 → 按出来正好是它的音节(64 → mi、ni)。
    private let nineKeyFull: [String: [UInt16]]
    /// 九宫格:数字串 → 以它开头、更长的音节(末音节没按完时补全)。
    private let nineKeyPrefixes: [String: [UInt16]]

    /// 九宫格的键位:2 = abc … 9 = wxyz。
    static let nineKeyLetters: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl", "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]
    static let nineKeyDigit: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (d, letters) in nineKeyLetters { for l in letters { map[l] = d } }
        return map
    }()
    /// 一串拼音在九宫格上怎么按(nihao → 64426)。
    static func nineKeyCode(_ s: String) -> String { String(s.compactMap { nineKeyDigit[$0] }) }

    static let initials: Set<String> = [
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
        "r", "z", "c", "s", "y", "w", "zh", "ch", "sh",
    ]

    init(lexicon: Lexicon, fuzzy: FuzzyOptions = [], correctionEnabled: Bool = true) {
        self.lexicon = lexicon
        self.fuzzy = fuzzy
        self.correctionEnabled = correctionEnabled
        var prefixes: [String: [UInt16]] = [:]
        for (i, s) in lexicon.syllables.enumerated() {
            for n in 1..<s.count { prefixes[String(s.prefix(n)), default: []].append(UInt16(i)) }
        }
        self.prefixes = prefixes

        var alternates: [String: [(UInt16, Bool)]] = [:]
        let index = lexicon.syllableIndex
        for (s, id) in index {
            // 韵尾 ng 打成 gn:xign、zhagn。
            if correctionEnabled, s.hasSuffix("ng"), s.count >= 3 {
                let typo = String(s.dropLast(2)) + "gn"
                if index[typo] == nil { alternates[typo, default: []].append((id, false)) }
            }
            for variant in Self.fuzzyVariants(of: s, options: fuzzy) where variant != s && index[variant] != nil {
                alternates[variant, default: []].append((id, true))
            }
        }
        self.alternates = alternates

        var missingVowel: [String: [UInt16]] = [:]
        for (s, id) in index where correctionEnabled && s.count >= 3 {
            let letters = Array(s)
            for position in 1..<letters.count where "aeiou".contains(letters[position]) {
                var shortened = letters
                shortened.remove(at: position)
                let key = String(shortened)
                if key.count >= 2 { missingVowel[key, default: []].append(id) }
            }
        }
        self.missingVowel = missingVowel

        var full: [String: [UInt16]] = [:], longer: [String: [UInt16]] = [:]
        for (i, s) in lexicon.syllables.enumerated() {
            let code = Self.nineKeyCode(s)
            guard code.count == s.count else { continue }
            full[code, default: []].append(UInt16(i))
            for n in 1..<max(code.count, 1) { longer[String(code.prefix(n)), default: []].append(UInt16(i)) }
        }
        self.nineKeyFull = full
        self.nineKeyPrefixes = longer
    }

    /// 数字串开头这几位能读成哪些音节(九宫格左边那列「选拼音」):长的在前,同长按 `rank` 排。
    func nineKeySyllables(_ digits: String, rank: (UInt16) -> Int) -> [(syllable: String, length: Int)] {
        var out: [(String, Int)] = []
        let chars = Array(digits.prefix { Self.nineKeyLetters[$0] != nil })
        for n in stride(from: min(chars.count, 6), through: 1, by: -1) {
            let ids = (nineKeyFull[String(chars.prefix(n))] ?? []).sorted { rank($0) < rank($1) }
            out += ids.map { (lexicon.syllables[Int($0)], n) }
        }
        // 最后是第一个键上的单个字母(声母/零声母韵母都可能)。
        if let first = chars.first, let letters = Self.nineKeyLetters[first] {
            out += letters.map { String($0) }.filter { s in !out.contains { $0.0 == s } }.map { ($0, 1) }
        }
        return out
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
        // 九宫格按出来的数字:一个数字串可以读成好几个音节(64 = mi / ni),交给词频去分。
        // 选过拼音的那几段已经换成字母(ni'426),照下面的全拼规则走。
        for i in 0..<n where Self.nineKeyLetters[raw[i]] != nil {
            var j = i
            var piece = ""
            while j < n, Self.nineKeyLetters[raw[j]] != nil, j - i < 6 {
                piece.append(raw[j])
                j += 1
                let atEnd = j == n || raw[j] == "'"
                if let ids = nineKeyFull[piece] { out[i].append(Token(end: j, ids: ids, kind: .full)) }
                if atEnd, let longer = nineKeyPrefixes[piece] { out[i].append(Token(end: j, ids: longer, kind: .partial)) }
            }
        }
        // 和数字混在一起的字母是在左边那列选定的拼音:只认这个音节本身,不补全、不纠错
        // (选了 mi 就是 mi,不能被补成 min)。
        let fixedLetters = raw.contains { Self.nineKeyLetters[$0] != nil }
        for i in 0..<n where raw[i] != "'" && raw[i].isLetter {
            var j = i
            var piece = ""
            while j < n, raw[j] != "'", raw[j].isLetter, j - i < 6 {
                piece.append(raw[j])
                j += 1
                let atEnd = j == n || raw[j] == "'"
                if let id = lexicon.syllableIndex[piece] {
                    out[i].append(Token(end: j, ids: [id], kind: .full))
                }
                if fixedLetters { continue }
                if let alt = alternates[piece] {
                    let fuzzyIDs = alt.filter(\.1).map(\.0), typoIDs = alt.filter { !$0.1 }.map(\.0)
                    if !fuzzyIDs.isEmpty { out[i].append(Token(end: j, ids: fuzzyIDs, kind: .fuzzy)) }
                    if !typoIDs.isEmpty { out[i].append(Token(end: j, ids: typoIDs, kind: .corrected)) }
                }
                // 中间的合法音节也可能漏敲元音:niha ya 应能读成 ni hao ya。
                // 只给短音节的有限个变体,仍保留精确路径参与排序。
                if !atEnd, piece.count >= 2, let ids = missingVowel[piece] {
                    out[i].append(Token(end: j, ids: Array(ids.prefix(8)), kind: .corrected))
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

/// 九宫格键位,给界面层用(2 = ABC … 9 = WXYZ)。
public enum NineKey {
    public static let letters: [Character: String] = Syllabifier.nineKeyLetters
}
