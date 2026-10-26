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
    /// 九宫格「重输」:丢掉正在拼的这一串。
    case clearComposition
    /// 九宫格的 1 键:拼的时候是分词(同长按「，」的分隔符),没在拼时打「@」。
    case nineKeyOne
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
    /// 钉在行的最左/最右、宽度取 `KeyboardMetrics.edgeKeyWidth`,中间的键照常按格子居中
    /// (系统键盘第三行:shift、删除贴边,z…m 和上面两行对齐,中间留出空隙)。
    public let edgeAnchored: Bool
    /// 按下时弹出放大气泡(只有字符键弹)。
    public var showsCallout: Bool {
        switch action { case .letter, .text: !isFunction; default: false }
    }

    public init(_ action: KeyAction, width: CGFloat = 1, isFunction: Bool = false,
                hold: KeyAction? = nil, hint: String? = nil, edge: Bool = false) {
        self.action = action
        self.width = width
        self.isFunction = isFunction
        self.holdAction = hold
        self.holdHint = hint
        self.edgeAnchored = edge
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
        // 照 iOS 系统拼音键盘:底行 123 / (地球) / 中英 / 空格 / 回车,回车 2.5 格;
        // 标点去 123 页打(系统键盘字母页也没有逗号句号)。
        var bottom: [Key] = [Key(.page(.numbers), width: 1.25, isFunction: true)]
        if needsGlobe { bottom.append(Key(.nextKeyboard, width: 1.25, isFunction: true)) }
        bottom.append(Key(.toggleLanguage, width: 1.25, isFunction: true))
        bottom.append(Key(.space, width: 0))
        bottom.append(Key(.returnKey, width: 2.5, isFunction: true))
        return [
            letterRow("qwertyuiop"),
            letterRow("asdfghjkl"),
            [Key(.shift, isFunction: true, edge: true)] + letterRow("zxcvbnm") + [Key(.delete, isFunction: true, edge: true)],
            bottom,
        ]
    }

    static func bottomRow(back: KeyboardPage, needsGlobe: Bool) -> [Key] {
        var row: [Key] = [Key(.page(back), width: needsGlobe ? 1.25 : 2.5, isFunction: true)]
        if needsGlobe { row.append(Key(.nextKeyboard, width: 1.25, isFunction: true)) }
        row.append(Key(.space, width: 0))
        row.append(Key(.returnKey, width: 2.5, isFunction: true))
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
    /// 第三行贴边的 shift / 删除有多宽(`Key.edgeAnchored`)。
    public var edgeKeyWidth: CGFloat

    /// 竖屏照 iOS 27 系统拼音键盘的真机截图量的(402pt 宽):字母键 33.4 宽 42 高、键缝 6、行距 10(截图是 12,用户要求再收 2)、两边 7;
    /// 第三行 shift / 删除 45 宽贴边;候选栏 53(首选垫一块 36 高的圆角底)。
    public static let phonePortrait = KeyboardMetrics(keyHeight: 42, rowSpacing: 10, keySpacing: 6, sideInset: 7,
                                                      topInset: 0, bottomInset: 0, cornerRadius: 8.5,
                                                      candidateBarHeight: 53, edgeKeyWidth: 45)
    public static let phoneLandscape = KeyboardMetrics(keyHeight: 34, rowSpacing: 6, keySpacing: 4, sideInset: 3,
                                                       topInset: 5, bottomInset: 3, cornerRadius: 7,
                                                       candidateBarHeight: 36, edgeKeyWidth: 0)
    public static let pad = KeyboardMetrics(keyHeight: 58, rowSpacing: 9, keySpacing: 10, sideInset: 7,
                                            topInset: 8, bottomInset: 8, cornerRadius: 9,
                                            candidateBarHeight: 50, edgeKeyWidth: 0)

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
            let top = r == 0 ? 0 : y - m.rowSpacing / 2
            let bottom = r == rows.count - 1 ? m.keyAreaHeight(rows: rows.count) : y + m.keyHeight + m.rowSpacing / 2
            // 贴边的键(第三行 shift / 删除)单独摆;中间的键照常按格子居中,和上面几行对齐。
            // `edgeKeyWidth` 为 0(横屏、iPad)时退回普通排法:按 1.5 格接在一起。
            let anchored = m.edgeKeyWidth > 0 && row.contains(where: \.edgeAnchored)
            let middle = anchored ? row.filter { !$0.edgeAnchored } : row.map {
                $0.edgeAnchored ? Key($0.action, width: 1.5, isFunction: $0.isFunction, hold: $0.holdAction, hint: $0.holdHint) : $0
            }
            let rowUnits = middle.reduce(0) { $0 + $1.width }
            let rowWidth = rowUnits * unit + CGFloat(middle.count - 1) * m.keySpacing
                + (rowUnits - CGFloat(middle.count)) * m.keySpacing // 宽键占掉的键缝也算进去
            var x = m.sideInset + (available - rowWidth) / 2
            var frames: [(Key, CGRect)] = []
            if anchored, let first = row.first, first.edgeAnchored {
                frames.append((first, CGRect(x: m.sideInset, y: y, width: m.edgeKeyWidth, height: m.keyHeight)))
            }
            for key in middle {
                let w = key.width * unit + (key.width - 1) * m.keySpacing
                frames.append((key, CGRect(x: x, y: y, width: w, height: m.keyHeight)))
                x += w + m.keySpacing
            }
            if anchored, let last = row.last, last.edgeAnchored {
                frames.append((last, CGRect(x: width - m.sideInset - m.edgeKeyWidth, y: y, width: m.edgeKeyWidth, height: m.keyHeight)))
            }
            // 触摸范围:向左右扩到和邻键的中线(贴边键和字母之间的空隙两边各分一半)。
            for (i, (key, frame)) in frames.enumerated() {
                let left = i == 0 ? 0 : (frames[i - 1].1.maxX + frame.minX) / 2
                let right = i == frames.count - 1 ? width : (frame.maxX + frames[i + 1].1.minX) / 2
                out.append(PlacedKey(key: key, frame: frame,
                                     hitFrame: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
        }
        return out
    }

    /// 九宫格(中文字母页):左边一列是标点 / 选拼音的竖条(`listFrame`,由视图自己摆),
    /// 中间 3×3 是 @/. ABC DEF / GHI JKL MNO / PQRS TUV WXYZ,右边一列 删除 / 重输 / 回车(占两行),
    /// 底行 123 / (地球) 中英 / 空格。总高和全键盘一样,换布局时键盘不跳。
    public static func placeNineKey(width: CGFloat, metrics m: KeyboardMetrics, needsGlobe: Bool)
        -> (keys: [PlacedKey], listFrame: CGRect) {
        let gap: CGFloat = 6
        let available = width - 2 * m.sideInset
        // 两边的窄列是中间大键的 3/4。
        let big = (available - 4 * gap) / 4.5, narrow = big * 0.75
        let colX: [CGFloat] = {
            var xs: [CGFloat] = [], x = m.sideInset
            for w in [narrow, big, big, big, narrow] { xs.append(x); x += w + gap }
            return xs
        }()
        let colW: [CGFloat] = [narrow, big, big, big, narrow]
        let total = m.keyAreaHeight(rows: 4)
        let rowGap: CGFloat = 6
        let rowH = (total - m.topInset - m.bottomInset - 3 * rowGap) / 4
        func y(_ r: Int) -> CGFloat { m.topInset + CGFloat(r) * (rowH + rowGap) }
        func rect(col: Int, row: Int, cols: Int = 1, rows: Int = 1) -> CGRect {
            let w = colX[col + cols - 1] + colW[col + cols - 1] - colX[col]
            return CGRect(x: colX[col], y: y(row), width: w, height: CGFloat(rows) * rowH + CGFloat(rows - 1) * rowGap)
        }
        var keys: [(Key, CGRect)] = [
            (Key(.nineKeyOne), rect(col: 1, row: 0)),
            (Key(.letter("2")), rect(col: 2, row: 0)), (Key(.letter("3")), rect(col: 3, row: 0)),
            (Key(.delete, isFunction: true), rect(col: 4, row: 0)),
            (Key(.letter("4")), rect(col: 1, row: 1)), (Key(.letter("5")), rect(col: 2, row: 1)),
            (Key(.letter("6")), rect(col: 3, row: 1)),
            (Key(.clearComposition, isFunction: true), rect(col: 4, row: 1)),
            (Key(.letter("7")), rect(col: 1, row: 2)), (Key(.letter("8")), rect(col: 2, row: 2)),
            (Key(.letter("9")), rect(col: 3, row: 2)),
            (Key(.returnKey, isFunction: true), rect(col: 4, row: 2, rows: 2)),
            (Key(.page(.numbers), isFunction: true), rect(col: 0, row: 3)),
            (Key(.space), rect(col: 2, row: 3, cols: 2)),
        ]
        let langCell = rect(col: 1, row: 3)
        if needsGlobe {
            let half = (langCell.width - gap) / 2
            keys.append((Key(.nextKeyboard, isFunction: true), CGRect(x: langCell.minX, y: langCell.minY, width: half, height: rowH)))
            keys.append((Key(.toggleLanguage, isFunction: true),
                         CGRect(x: langCell.maxX - half, y: langCell.minY, width: half, height: rowH)))
        } else {
            keys.append((Key(.toggleLanguage, isFunction: true), langCell))
        }
        // 触摸范围:向四周扩到键缝中线,贴边的扩到边。
        let placed = keys.map { key, f in
            let left = f.minX <= m.sideInset + 0.5 ? 0 : f.minX - gap / 2
            let right = f.maxX >= width - m.sideInset - 0.5 ? width : f.maxX + gap / 2
            let top = f.minY <= m.topInset + 0.5 ? 0 : f.minY - rowGap / 2
            let bottom = f.maxY >= total - m.bottomInset - 0.5 ? total : f.maxY + rowGap / 2
            return PlacedKey(key: key, frame: f, hitFrame: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        return (placed, rect(col: 0, row: 0, rows: 3))
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
