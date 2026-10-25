import Foundation

/// 中英文标点。中文页的逗号句号是全角,英文页是半角。
public struct Punctuation: Sendable {
    public let comma: String
    public let period: String

    public static func table(_ language: InputLanguage) -> Punctuation {
        language == .chinese ? Punctuation(comma: "，", period: "。") : Punctuation(comma: ",", period: ".")
    }

    /// 成对的引号按光标前已有几个左引号决定打左还是右:中文“”‘’,英文直引号不配对。
    public static func resolveQuote(_ text: String, before: String) -> String {
        let pairs: [String: (open: Character, close: Character)] = ["“": ("“", "”"), "”": ("“", "”"),
                                                                     "‘": ("‘", "’"), "’": ("‘", "’")]
        guard let pair = pairs[text] else { return text }
        let opens = before.filter { $0 == pair.open }.count
        let closes = before.filter { $0 == pair.close }.count
        return String(opens > closes ? pair.close : pair.open)
    }

    /// 句末标点:英文自动大写看这个。
    static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
}
