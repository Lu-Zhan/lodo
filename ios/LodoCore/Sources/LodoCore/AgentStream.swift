import Foundation

/// SSE 流式回复的纯解析逻辑。网络层只负责把字节切成行喂进来,这里一行不碰
/// URLSession,可以离线单测(`AgentStreamTests`)。
public enum AgentStream {
    /// 一行 SSE 的含义。忽略的行(空行、`:` 心跳、没有 choices 的行)返回 nil。
    public enum Event: Equatable {
        /// 一片增量。content 是正文(我们协议里是 JSON 的碎片),
        /// reasoning 是推理模型先吐的思考过程。
        case delta(content: String?, reasoning: String?)
        /// 服务端报的 token 用量。请求体带了 `stream_options.include_usage` 才会有。
        /// **它不一定单独占一片**:OpenAI 是 `choices` 空数组的一片,DeepSeek 是
        /// 搭在最后那片 `finish_reason: "stop"` 上、delta 里 content 是空串。所以
        /// 判据是"这片没有可显示的增量",而不是"choices 是空的"——真有内容的那片
        /// 仍然走 delta,内容一个字都不能丢。
        case usage(input: Int?, output: Int?)
        case done
    }

    /// 解析一行 SSE。行切分交给 `URLSession.bytes.lines`——自己维护跨 chunk 的
    /// 半行状态机没必要,少一类 bug。
    public static func parseLine(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `:` 开头是注释/心跳行(有的网关拿它保活)。
        guard !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return .done }
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any] else { return nil }
        let delta = (root["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
        let content = delta?["content"] as? String
        // reasoning_content 是 DeepSeek 的字段名,reasoning 是另一些兼容服务商的。
        let reasoning = (delta?["reasoning_content"] as? String) ?? (delta?["reasoning"] as? String)
        // 空串不算增量:收流那边本来就会跳过它,而 DeepSeek 正是把 usage 搭在
        // 这样一片空 delta 上,当成 delta 处理就再也读不到 token 数了。
        if !(content ?? "").isEmpty || !(reasoning ?? "").isEmpty {
            return .delta(content: content, reasoning: reasoning)
        }
        if let usage = root["usage"] as? [String: Any] {
            let input = usage["prompt_tokens"] as? Int
            let output = usage["completion_tokens"] as? Int
            if input != nil || output != nil { return .usage(input: input, output: output) }
        }
        return nil
    }
}

/// 从**还没收完**的 `command` JSON 里,增量抽出 `answer` 那条动作的正文,
/// 好在等整包之前就把字先显示出来。
///
/// 只认一种形状:`{"actions": [{"action": "answer", "text": "…"}]}` 的第一条动作。
/// **必须按 action 的值门控**,不能只扫 `"text"` 键——`memorize`/`auto_memorize`/
/// `suggest_memorize` 的 payload 里同样有 `text`,只扫键会把记忆正文先流进气泡、
/// 再被收藏结果卡片顶掉。三态:还没看到 action 时先缓冲不吐,确认是 answer 才
/// 补吐并实时跟进,是别的动作就永久闭嘴(ReAct 的工具调用轮次连 actions 都没有,
/// 天然一个字都不吐,所以不需要预判"哪一轮才是最后一轮")。
public struct AnswerStreamScanner {
    private var raw = ""
    private var visible = ""
    private var rejected = false

    public init() {}

    /// 喂进一片增量,返回"到目前为止可以安全显示的全文"(变了才返回,没变返回 nil)。
    /// 永远不会吐出半个转义序列——`\n` 收了一半、`\uD83D` 还没等到配对的低位
    /// 代理项时,都停在它前面等下一片。
    public mutating func consume(_ delta: String) -> String? {
        guard !rejected else { return nil }
        raw += delta
        guard let result = Self.scanFirstAction(in: raw) else { return nil }
        if let action = result.action, action != "answer" {
            rejected = true
            visible = ""
            return nil
        }
        // action 还没露面时先攒着不吐:这时候还分不清它是 answer 还是 memorize。
        guard result.action == "answer", let text = result.text, text != visible else { return nil }
        visible = text
        return visible
    }

    /// 已经吐出去的全文。
    public var currentText: String { visible }
    /// 这一轮确定不是 answer(已经永久闭嘴)。
    public var isRejected: Bool { rejected }

    // MARK: - 容错扫描

    struct FirstAction: Equatable {
        var action: String?
        var text: String?
    }

    /// 在(可能被截断的)JSON 里找 `actions` 数组第一个对象的 action / text。
    /// 每次从头重扫而不是维护增量状态机:回复至多几 KB,重扫的代价远小于
    /// 一个写错就会吐出乱码的状态机。
    static func scanFirstAction(in raw: String) -> FirstAction? {
        let chars = Array(raw)
        guard let actionsKey = indexOfKey("actions", in: chars) else { return nil }
        var i = actionsKey
        // "actions" 之后依次找 `[`、`{`。
        guard let bracket = firstIndex(of: "[", from: i, in: chars) else { return nil }
        i = bracket + 1
        guard let brace = firstIndex(of: "{", from: i, in: chars) else { return nil }
        i = brace + 1

        var result = FirstAction()
        while i < chars.count {
            i = skipWhitespace(from: i, in: chars)
            guard i < chars.count else { return result }
            if chars[i] == "}" { return result }
            guard chars[i] == "\"" else { return result }
            guard let key = readString(from: &i, in: chars), key.closed else { return result }
            i = skipWhitespace(from: i, in: chars)
            guard i < chars.count, chars[i] == ":" else { return result }
            i += 1
            i = skipWhitespace(from: i, in: chars)
            guard i < chars.count else { return result }
            if chars[i] == "\"" {
                guard let value = readString(from: &i, in: chars) else { return result }
                if key.value == "action" {
                    // action 的值没收完就先不当数(免得把 "an" 当成不是 answer)。
                    if value.closed { result.action = value.value }
                } else if key.value == "text" {
                    result.text = value.value
                }
                if !value.closed { return result }
            } else if chars[i] == "{" || chars[i] == "[" {
                guard let end = skipContainer(from: i, in: chars) else { return result }
                i = end
            } else {
                // 数字/true/false/null:读到分隔符为止。
                while i < chars.count, chars[i] != ",", chars[i] != "}" { i += 1 }
            }
            i = skipWhitespace(from: i, in: chars)
            guard i < chars.count else { return result }
            if chars[i] == "," { i += 1; continue }
            return result
        }
        return result
    }

    private static func indexOfKey(_ key: String, in chars: [Character]) -> Int? {
        let needle = Array("\"\(key)\"")
        guard chars.count >= needle.count else { return nil }
        for start in 0...(chars.count - needle.count) where Array(chars[start..<(start + needle.count)]) == needle {
            return start + needle.count
        }
        return nil
    }

    private static func firstIndex(of target: Character, from index: Int, in chars: [Character]) -> Int? {
        var i = index
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func skipWhitespace(from index: Int, in chars: [Character]) -> Int {
        var i = index
        while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\r" || chars[i] == "\t" {
            i += 1
        }
        return i
    }

    /// 跳过一个完整的 `{}` / `[]`;没收完返回 nil。
    private static func skipContainer(from index: Int, in chars: [Character]) -> Int? {
        var depth = 0
        var i = index
        var inString = false
        var escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" {
                depth += 1
            } else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return nil
    }

    struct ScannedString { var value: String; var closed: Bool }

    /// 从开引号处读一个 JSON 字符串,顺带反转义。没收完(closed == false)时
    /// 返回**已经能安全显示的那一段**:停在未完成的转义序列之前。
    private static func readString(from index: inout Int, in chars: [Character]) -> ScannedString? {
        guard index < chars.count, chars[index] == "\"" else { return nil }
        var i = index + 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                index = i + 1
                return ScannedString(value: out, closed: true)
            }
            if c != "\\" {
                out.append(c)
                i += 1
                continue
            }
            // 转义序列:没收全就停在反斜杠前面,别吐半个。
            guard i + 1 < chars.count else {
                index = i
                return ScannedString(value: out, closed: false)
            }
            let next = chars[i + 1]
            if next == "u" {
                guard let (scalarText, consumed) = readUnicodeEscape(at: i, in: chars) else {
                    index = i
                    return ScannedString(value: out, closed: false)
                }
                out += scalarText
                i += consumed
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            default: out.append(next)
            }
            i += 2
        }
        index = i
        return ScannedString(value: out, closed: false)
    }

    /// 读 `\uXXXX`(必要时连着读配对的低位代理项)。收不全返回 nil,
    /// 让调用方停在这个转义序列之前——半个代理项显示出来是个乱码方块。
    private static func readUnicodeEscape(at index: Int, in chars: [Character])
        -> (text: String, consumed: Int)? {
        guard let high = hexScalar(at: index, in: chars) else { return nil }
        if high < 0xD800 || high > 0xDBFF {
            guard let scalar = Unicode.Scalar(high) else { return nil }
            return (String(Character(scalar)), 6)
        }
        // 高位代理项:必须等到配对的低位。
        guard let low = hexScalar(at: index + 6, in: chars), low >= 0xDC00, low <= 0xDFFF else {
            return nil
        }
        let combined = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        guard let scalar = Unicode.Scalar(combined) else { return nil }
        return (String(Character(scalar)), 12)
    }

    private static func hexScalar(at index: Int, in chars: [Character]) -> UInt32? {
        guard index + 5 < chars.count, chars[index] == "\\", chars[index + 1] == "u" else {
            return nil
        }
        let digits = String(chars[(index + 2)...(index + 5)])
        return UInt32(digits, radix: 16)
    }
}

/// 流式增量的节流:每个 token 都触发一次 SwiftUI 重排,长回复上是实打实的开销。
/// 攒够间隔或遇到换行(视觉上正好是一段结束)才放行。`now` 由调用方传入,
/// 便于离线单测。
public struct StreamThrottle {
    public static let interval: TimeInterval = 0.08

    private var lastFlush: Date?
    public init() {}

    /// 这一片要不要立刻放行。
    public mutating func shouldFlush(_ delta: String, now: Date = Date()) -> Bool {
        if delta.contains("\n") || delta.contains("\\n") {
            lastFlush = now
            return true
        }
        guard let last = lastFlush else {
            lastFlush = now
            return true
        }
        guard now.timeIntervalSince(last) >= Self.interval else { return false }
        lastFlush = now
        return true
    }
}
