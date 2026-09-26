import Foundation

/// 拼音组合与候选排序。词库由键盘 target 加载,核心层不依赖 UIKit。
public struct PinyinIME {
    public struct Entry: Equatable {
        public let pinyin: String
        public let word: String
        public let weight: Int
        public init(pinyin: String, word: String, weight: Int) {
            self.pinyin = pinyin; self.word = word; self.weight = weight
        }
    }

    public private(set) var raw = ""
    public private(set) var committed = ""
    private var compositionKey: String?
    private let entries: [Entry]
    private var learned: [String: String]
    private let syllables: Set<String>

    public init(entries: [Entry], learned: [String: String] = [:]) {
        self.entries = entries
        self.learned = learned
        self.syllables = Set(entries.flatMap { $0.pinyin.split(separator: "'").map(String.init) })
    }

    public static func load(_ text: String, learned: [String: String] = [:]) -> PinyinIME {
        let entries = text.split(separator: "\n").compactMap { line -> Entry? in
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let weight = Int(fields[2]) else { return nil }
            return Entry(pinyin: String(fields[0]), word: String(fields[1]), weight: weight)
        }
        return PinyinIME(entries: entries, learned: learned)
    }

    public mutating func type(_ letter: String) { raw += letter.lowercased() }
    public mutating func delete() {
        if !raw.isEmpty { raw.removeLast() }
        else if !committed.isEmpty { committed.removeLast() }
    }
    public mutating func clear() { raw = ""; committed = ""; compositionKey = nil }

    /// 按完整音节切分优先,同段数时取更长的首段。显式单引号强制分段。
    public func segments(_ input: String) -> [String] {
        input.split(separator: "'", omittingEmptySubsequences: false).flatMap { part in
            let s = String(part)
            guard !s.isEmpty else { return [String]() }
            var best: [[String]?] = Array(repeating: nil, count: s.count + 1)
            best[s.count] = []
            for i in stride(from: s.count - 1, through: 0, by: -1) {
                let suffix = String(s.dropFirst(i))
                for length in stride(from: min(6, suffix.count), through: 1, by: -1) {
                    let head = String(suffix.prefix(length))
                    let isLast = i + length == s.count
                    guard syllables.contains(head) || (isLast && syllables.contains(where: { $0.hasPrefix(head) })) else { continue }
                    guard let rest = best[i + length] else { continue }
                    let candidate = [head] + rest
                    if best[i] == nil || candidate.count < best[i]!.count { best[i] = candidate }
                }
            }
            return best[0] ?? [s]
        }
    }

    public var candidates: [String] {
        guard !raw.isEmpty else { return [] }
        let parts = segments(raw)
        let joined = parts.joined()
        var matches: [(String, Int)] = []
        if let learnedWord = learned[joined] { matches.append((learnedWord, 1_000_000)) }
        for entry in entries {
            let key = entry.pinyin.replacingOccurrences(of: "'", with: "")
            let syllableParts = entry.pinyin.split(separator: "'").map(String.init)
            let exact = key == joined
            let abbreviated = syllableParts.count > 1 &&
                String(syllableParts.compactMap(\.first)) == joined
            let finalPrefix = parts.count == syllableParts.count &&
                zip(parts, syllableParts).dropLast().allSatisfy { $0 == $1 } &&
                (syllableParts.last?.hasPrefix(parts.last ?? "") ?? false)
            let shorter = joined.hasPrefix(key) && key.count < joined.count
            guard exact || abbreviated || finalPrefix || shorter else { continue }
            let tier = exact ? 100_000 : (abbreviated ? 80_000 : (finalPrefix ? 60_000 : 20_000))
            matches.append((entry.word, tier + entry.weight))
        }
        var seen = Set<String>()
        return matches.sorted { $0.1 > $1.1 }.compactMap { seen.insert($0.0).inserted ? $0.0 : nil }.prefix(30).map { $0 }
    }

    /// 单字逐段选择时保留待上屏的部分;整句选择时学习用户词。
    public mutating func select(_ word: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let parts = segments(raw)
        if word.count == 1 && parts.count > 1 {
            if compositionKey == nil { compositionKey = raw.replacingOccurrences(of: "'", with: "") }
            committed += word
            raw = parts.dropFirst().joined(separator: "'")
            return nil
        }
        let key = compositionKey ?? raw.replacingOccurrences(of: "'", with: "")
        let result = committed + word
        if parts.allSatisfy({ syllables.contains($0) }) { learned[key] = result }
        clear()
        return result
    }

    public func learnedWords() -> [String: String] { learned }
}
