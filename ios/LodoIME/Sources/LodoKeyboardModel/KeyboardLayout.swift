import CoreGraphics
import Foundation

/// 键盘当前显示哪一页。
public enum KeyboardPage: Hashable, Sendable {
    case letters
    case numbers
    case symbols
}

/// 打出来的是中文(拼音)还是英文。
public enum InputLanguage: Hashable, Sendable {
    case chinese
    case english
}

/// 一颗键按下去做什么。
public enum KeyAction: Hashable, Sendable {
    /// 字母:中文时进拼音组合,英文时直接上屏(大小写由 shift 决定)。
    case letter(Character)
    /// 原样上屏的字符(数字、标点、符号)。
    case text(String)
    case shift
    case delete
    /// 删除键按住久了:按词删(英文删到上个单词开头,中文仍逐字)。
    case deleteWord
    /// 拼音分隔符(长按「，」):拼到一半时把 xian 分成 xi'an;没在拼时打半角逗号。
    case separator
    case space
    case returnKey
    case page(KeyboardPage)
    case toggleLanguage
    /// 系统的切换输入法键(只在 `needsInputModeSwitchKey` 时出现)。
    case nextKeyboard
}

public struct Key: Hashable, Sendable {
    public let action: KeyAction
    /// 宽度,以一颗字母键为 1;0 = 弹性,把这一行补满 10 个单位(空格)。
    public let width: CGFloat
    /// 0 = 字母、数字一类的普通键;1 = shift、删除一类的功能键(配色不同)。
    public let isFunction: Bool
    /// 长按的另一个动作(角上小字提示),按住超过 `KeyAreaView` 的门槛松手时执行它而不是 `action`。
    public let holdAction: KeyAction?
    /// 角上的小字提示。
    public let holdHint: String?
    /// 按下时弹出放大气泡(只有字符键弹)。
    public var showsCallout: Bool {
        switch action { case .letter, .text: !isFunction; default: false }
    }

    public init(_ action: KeyAction, width: CGFloat = 1, isFunction: Bool = false,
                hold: KeyAction? = nil, hint: String? = nil) {
        self.action = action
        self.width = width
        self.isFunction = isFunction
        self.holdAction = hold
        self.holdHint = hint
    }
}

/// 一页键盘的键位。照系统中文全拼键盘的排法,只多一颗「中/英」。
public enum KeyboardLayout {
    public static func rows(page: KeyboardPage, language: InputLanguage, needsGlobe: Bool) -> [[Key]] {
        switch page {
        case .letters: letters(language: language, needsGlobe: needsGlobe)
        case .numbers: numbers(language: language, needsGlobe: needsGlobe)
        case .symbols: symbols(language: language, needsGlobe: needsGlobe)
        }
    }

    static func letterRow(_ s: String) -> [Key] { s.map { Key(.letter($0)) } }
    static func textRow(_ items: [String]) -> [Key] { items.map { Key(.text($0)) } }

    static func letters(language: InputLanguage, needsGlobe: Bool) -> [[Key]] {
        let p = Punctuation.table(language)
        var bottom: [Key] = [Key(.page(.numbers), width: 1.25, isFunction: true)]
        if needsGlobe { bottom.append(Key(.nextKeyboard, isFunction: true)) }
        bottom.append(Key(.toggleLanguage, width: needsGlobe ? 1 : 1.25, isFunction: true))
        // 中文页空格两边给常用的逗号句号:打中文时这两个最常用,不用每次切到 123。
        // 长按:逗号 → 拼音分隔符 / 半角逗号,句号 → 半角句点。
        if language == .chinese { bottom.append(Key(.text(p.comma), hold: .separator, hint: "'")) }
        bottom.append(Key(.space, width: 0))
        if language == .chinese { bottom.append(Key(.text(p.period), hold: .text("."), hint: ".")) }
        bottom.append(Key(.returnKey, width: 1.75, isFunction: true))
        return [
            letterRow("qwertyuiop"),
            letterRow("asdfghjkl"),
            [Key(.shift, width: 1.5, isFunction: true)] + letterRow("zxcvbnm") + [Key(.delete, width: 1.5, isFunction: true)],
            bottom,
        ]
    }

    static func bottomRow(back: KeyboardPage, needsGlobe: Bool) -> [Key] {
        var row: [Key] = [Key(.page(back), width: 1.25, isFunction: true)]
        if needsGlobe { row.append(Key(.nextKeyboard, width: 1.25, isFunction: true)) }
        row.append(Key(.space, width: 0))
        row.append(Key(.returnKey, width: 1.75, isFunction: true))
        return row
    }

    static func numbers(language: InputLanguage, needsGlobe: Bool) -> [[Key]] {
        let second: [String] = language == .chinese
            ? ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"]
            : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
        let third: [String] = language == .chinese
            ? ["。", "，", "、", "？", "！", "."]
            : [".", ",", "?", "!", "'"]
        return [
            textRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]),
            textRow(second),
            [Key(.page(.symbols), width: 1.5, isFunction: true)] + thirdRow(third) + [Key(.delete, width: 1.5, isFunction: true)],
            bottomRow(back: .letters, needsGlobe: needsGlobe),
        ]
    }

    static func symbols(language: InputLanguage, needsGlobe: Bool) -> [[Key]] {
        let first: [String] = language == .chinese
            ? ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="]
            : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
        let second: [String] = language == .chinese
            ? ["_", "—", "\\", "|", "～", "《", "》", "$", "&", "·"]
            : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
        let third: [String] = language == .chinese
            ? ["…", "，", "^_^", "？", "！", "‘", "’"]
            : [".", ",", "?", "!", "'"]
        return [
            textRow(first),
            textRow(second),
            [Key(.page(.numbers), width: 1.5, isFunction: true)] + thirdRow(third) + [Key(.delete, width: 1.5, isFunction: true)],
            bottomRow(back: .letters, needsGlobe: needsGlobe),
        ]
    }

    /// 第三行中间几颗把 7 个字母键的宽度平分(系统也是这么做的:标点少的那页键更宽)。
    static func thirdRow(_ items: [String]) -> [Key] {
        let w = 7 / CGFloat(items.count)
        return items.map { Key(.text($0), width: w) }
    }
}

/// 键位尺寸。数值是 iOS 26 系统键盘的估计值,真机截图比对后在这里改。
public struct KeyboardMetrics: Sendable {
    public var keyHeight: CGFloat
    public var rowSpacing: CGFloat
    public var keySpacing: CGFloat
    public var sideInset: CGFloat
    public var topInset: CGFloat
    public var bottomInset: CGFloat
    public var cornerRadius: CGFloat
    public var candidateBarHeight: CGFloat

    /// 竖屏数值是用户真机试用后定的:键帽 44、键缝 6、两边 6、行距 6、顶部留 8、底部不留;
    /// 候选栏 40 = 拼音行 20 + 候选字 20(`CandidateBarView.preeditStrip`)。
    public static let phonePortrait = KeyboardMetrics(keyHeight: 44, rowSpacing: 6, keySpacing: 6, sideInset: 6,
                                                      topInset: 8, bottomInset: 0, cornerRadius: 8.5, candidateBarHeight: 40)
    public static let phoneLandscape = KeyboardMetrics(keyHeight: 34, rowSpacing: 6, keySpacing: 4, sideInset: 3,
                                                       topInset: 5, bottomInset: 3, cornerRadius: 7, candidateBarHeight: 32)
    public static let pad = KeyboardMetrics(keyHeight: 58, rowSpacing: 9, keySpacing: 10, sideInset: 7,
                                            topInset: 8, bottomInset: 8, cornerRadius: 9, candidateBarHeight: 44)

    /// 键区(不含候选栏)的总高度。
    public func keyAreaHeight(rows: Int) -> CGFloat {
        topInset + CGFloat(rows) * keyHeight + CGFloat(max(rows - 1, 0)) * rowSpacing + bottomInset
    }
}

/// 一颗键摆在哪、可点范围多大。
public struct PlacedKey: Sendable {
    public let key: Key
    /// 画出来的键帽。
    public let frame: CGRect
    /// 触摸归属范围:键帽向四周扩到相邻键的中线,整块键区没有死角。
    public let hitFrame: CGRect
}

public enum KeyboardFrames {
    /// 按宽度单位排一页键。一行的单位总数小于 10 时(第二行 9 个字母)整行居中,两端空出来的那截
    /// 归到最边上的键的触摸范围里——系统键盘点 a 左边的空白也是 a。
    public static func place(_ rows: [[Key]], width: CGFloat, metrics m: KeyboardMetrics) -> [PlacedKey] {
        let units: CGFloat = 10
        let available = width - 2 * m.sideInset
        let unit = (available - (units - 1) * m.keySpacing) / units
        var out: [PlacedKey] = []
        for (r, var row) in rows.enumerated() {
            let fixed = row.reduce(0) { $0 + $1.width }
            if let flex = row.firstIndex(where: { $0.width == 0 }) {
                let k = row[flex]
                row[flex] = Key(k.action, width: max(units - fixed, 1), isFunction: k.isFunction,
                                hold: k.holdAction, hint: k.holdHint)
            }
            let y = m.topInset + CGFloat(r) * (m.keyHeight + m.rowSpacing)
            let rowUnits = row.reduce(0) { $0 + $1.width }
            let rowWidth = rowUnits * unit + CGFloat(row.count - 1) * m.keySpacing
                + (rowUnits - CGFloat(row.count)) * m.keySpacing // 宽键占掉的键缝也算进去
            var x = m.sideInset + (available - rowWidth) / 2
            let top = r == 0 ? 0 : y - m.rowSpacing / 2
            let bottom = r == rows.count - 1 ? m.keyAreaHeight(rows: rows.count) : y + m.keyHeight + m.rowSpacing / 2
            for (i, key) in row.enumerated() {
                let w = key.width * unit + (key.width - 1) * m.keySpacing
                let frame = CGRect(x: x, y: y, width: w, height: m.keyHeight)
                let left = i == 0 ? 0 : x - m.keySpacing / 2
                let right = i == row.count - 1 ? width : x + w + m.keySpacing / 2
                out.append(PlacedKey(key: key, frame: frame,
                                     hitFrame: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
                x += w + m.keySpacing
            }
        }
        return out
    }

    /// 触点落在哪颗键:先看触摸范围,都不在(理论上不会)就取最近的键帽。
    public static func key(at point: CGPoint, in placed: [PlacedKey]) -> Int? {
        if let i = placed.firstIndex(where: { $0.hitFrame.contains(point) }) { return i }
        return placed.indices.min { distance(point, placed[$0].frame) < distance(point, placed[$1].frame) }
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
