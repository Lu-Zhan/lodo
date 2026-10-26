import Foundation

/// 通讯录、人脉和用户短语组成的只读词库。与会衰减淘汰的打字学习词分开。
public struct PersonalDictionary: Sendable {
    public struct Snapshot: Codable, Sendable {
        public let version: Int
        public let words: [Word]
        public init(version: Int = 1, words: [Word]) { self.version = version; self.words = words }
    }
    public struct Word: Codable, Hashable, Sendable {
        public let text: String
        /// 无声调、空格分隔的规范拼音,例如 "zhang san"。
        public let pinyin: String
        public init(text: String, pinyin: String) { self.text = text; self.pinyin = pinyin }
    }

    private var buckets: [String: [String]] = [:]
    private var prefixes: Set<String> = []

    public init(words: [Word], lexicon: Lexicon) {
        for word in words.prefix(20_000) {
            let sounds = word.pinyin.lowercased().split(whereSeparator: { $0 == " " || $0 == "'" }).map(String.init)
            guard !word.text.isEmpty, !sounds.isEmpty, sounds.count <= 8 else { continue }
            let ids = sounds.compactMap { lexicon.syllableIndex[$0] }
            guard ids.count == sounds.count else { continue }
            let key = Self.key(ids)
            if !buckets[key, default: []].contains(word.text) { buckets[key, default: []].append(word.text) }
            for n in 1...ids.count { prefixes.insert(Self.key(Array(ids.prefix(n)))) }
        }
    }

    private static func key(_ ids: [UInt16]) -> String { ids.map(String.init).joined(separator: ",") }
    func hasPhrase(withPrefix ids: [UInt16]) -> Bool { prefixes.contains(Self.key(ids)) }
    func words(for ids: [UInt16]) -> [(word: String, cost: Int)] {
        (buckets[Self.key(ids)] ?? []).map { ($0, 350) }
    }
    public var isEmpty: Bool { buckets.isEmpty }
}
