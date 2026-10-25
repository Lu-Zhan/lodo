#if os(iOS)
import UIKit

@MainActor
protocol CandidateBarDelegate: AnyObject {
    func candidateBar(select index: Int)
    func candidateBarToggleExpanded()
    func candidateBarDismissKeyboard()
    func candidateBarAsk()
}

/// 候选按钮池:每敲一个字母候选都会全换,按钮复用,不每次新建几十个视图。
@MainActor
final class CandidateButtons {
    private var pool: [UIButton] = []
    private let action: (Int) -> Void

    init(action: @escaping (Int) -> Void) { self.action = action }

    func buttons(count: Int, in container: UIView) -> [UIButton] {
        while pool.count < count {
            let i = pool.count
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            config.baseForegroundColor = .label
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.action(i) })
            pool.append(b)
        }
        for (i, b) in pool.enumerated() {
            if i < count {
                if b.superview !== container { container.addSubview(b) }
                b.isHidden = false
            } else {
                b.isHidden = true
            }
        }
        return Array(pool.prefix(count))
    }

    static func set(_ b: UIButton, _ text: String, emphasized: Bool, secondary: Bool = false, topInset: CGFloat = 0) {
        b.configuration?.attributedTitle = AttributedString(text, attributes: AttributeContainer([
            .font: emphasized ? UIFont.systemFont(ofSize: 19, weight: .semibold) : KeyboardAppearance.candidateFont,
        ]))
        b.configuration?.baseForegroundColor = secondary ? .secondaryLabel : .label
        b.configuration?.contentInsets.top = topInset
        b.accessibilityLabel = text
    }
}

/// 键区上方那一条:正在拼时是「拼音切分 + 横排候选 + 展开键」,没在拼时是工具条。
final class CandidateBarView: UIView {
    weak var delegate: CandidateBarDelegate?
    private let preedit = UILabel()
    private let scroll = UIScrollView()
    private lazy var buttons = CandidateButtons { [weak self] in self?.delegate?.candidateBar(select: $0) }
    private let expand = UIButton(type: .system)
    private let dismiss = UIButton(type: .system)
    private let ask = UIButton(type: .system)
    private let divider = UIView()
    /// 没在拼的时候左边露出 ✨(宿主接了 lodo 服务才有)。
    var showsLodoKeys = false
    private var items: [String] = []
    /// 横排最多摆这么多条,剩下的展开看。
    static let inlineLimit = 24

    var isExpanded = false {
        didSet { expand.configuration?.image = UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down") }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        preedit.font = KeyboardAppearance.preeditFont
        preedit.textColor = .secondaryLabel
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        var expandConfig = UIButton.Configuration.plain()
        expandConfig.image = UIImage(systemName: "chevron.down")
        expandConfig.baseForegroundColor = .label
        expand.configuration = expandConfig
        expand.accessibilityLabel = String(localized: "更多候选")
        expand.addAction(UIAction { [weak self] _ in self?.delegate?.candidateBarToggleExpanded() }, for: .touchUpInside)
        dismiss.tintColor = .label
        dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismiss.accessibilityLabel = String(localized: "收起键盘")
        dismiss.addAction(UIAction { [weak self] _ in self?.delegate?.candidateBarDismissKeyboard() }, for: .touchUpInside)
        ask.tintColor = KeyboardAppearance.accent.accent
        ask.setImage(UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        ask.accessibilityLabel = String(localized: "问 lodo")
        ask.addAction(UIAction { [weak self] _ in self?.delegate?.candidateBarAsk() }, for: .touchUpInside)
        divider.backgroundColor = .separator
        [preedit, scroll, expand, dismiss, ask, divider].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyAccent() { ask.tintColor = KeyboardAppearance.accent.accent }

    /// 拼音那一行的高度;候选按钮的可点范围铺满整栏(含这一行),字画在它下面。
    static let preeditStrip: CGFloat = 14

    /// `preedit` 为 nil = 没在拼(英文补全也走这里,只是不显示拼音行)。
    /// `secondaryIndex`:画成灰字的那一项(原样字母)。
    func show(preedit text: String?, items: [String], secondaryIndex: Int? = nil) {
        let changed = items != self.items
        self.items = items
        preedit.text = text
        preedit.isHidden = text == nil
        let strip = text == nil ? 0 : Self.preeditStrip
        let visible = Array(items.prefix(Self.inlineLimit))
        let bs = buttons.buttons(count: visible.count, in: scroll)
        for (i, b) in bs.enumerated() {
            CandidateButtons.set(b, visible[i], emphasized: i == 0 && text != nil,
                                 secondary: i == secondaryIndex, topInset: strip)
        }
        // 只有候选真的换了才滚回开头(布局回调也会走到这里,不能把用户翻到一半的候选拉回去)。
        if changed { scroll.contentOffset = .zero }
        expand.isHidden = items.count <= 1
        divider.isHidden = expand.isHidden
        dismiss.isHidden = !items.isEmpty
        ask.isHidden = !items.isEmpty || !showsLodoKeys
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 候选栏压得很矮(键盘总高由系统定,省下来的给按键),拼音那行只留 14pt;
        // 但候选和展开键的可点范围是整栏高度,快速选词不至于点空。
        let strip: CGFloat = preedit.isHidden ? 0 : Self.preeditStrip
        preedit.frame = CGRect(x: 12, y: 1, width: bounds.width - 24, height: strip - 1)
        let side: CGFloat = 44
        let rowH = bounds.height
        expand.frame = CGRect(x: bounds.width - side, y: 0, width: side, height: rowH)
        expand.configuration?.contentInsets = NSDirectionalEdgeInsets(top: strip, leading: 0, bottom: 0, trailing: 0)
        divider.frame = CGRect(x: bounds.width - side, y: strip + (rowH - strip) * 0.25,
                               width: 1 / max(traitCollection.displayScale, 1), height: (rowH - strip) * 0.5)
        dismiss.frame = CGRect(x: bounds.width - side - 4, y: 0, width: side, height: bounds.height)
        ask.frame = CGRect(x: 4, y: 0, width: side, height: bounds.height)
        scroll.frame = CGRect(x: 2, y: 0, width: bounds.width - 2 - (expand.isHidden ? 0 : side), height: rowH)
        var x: CGFloat = 0
        for b in scroll.subviews.compactMap({ $0 as? UIButton }) where !b.isHidden {
            let w = max(b.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: rowH)).width, 40)
            b.frame = CGRect(x: x, y: 0, width: w, height: rowH)
            x += w
        }
        scroll.contentSize = CGSize(width: x, height: rowH)
    }
}

/// 展开后的全部候选:盖在键区上,自动换行,竖着滚。
final class CandidateGridView: UIView {
    var onSelect: ((Int) -> Void)?
    private let scroll = UIScrollView()
    private lazy var buttons = CandidateButtons { [weak self] in self?.onSelect?($0) }
    private var items: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `resetScroll`:刚展开时回到顶上;之后的刷新(布局回调)只有候选真的变了才回去。
    func show(_ items: [String], resetScroll: Bool = false) {
        let changed = items != self.items
        self.items = items
        let bs = buttons.buttons(count: items.count, in: scroll)
        for (i, b) in bs.enumerated() { CandidateButtons.set(b, items[i], emphasized: false) }
        if changed || resetScroll { scroll.contentOffset = .zero }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let rowH: CGFloat = 48, inset: CGFloat = 6
        let width = bounds.width - 2 * inset
        // 一格至少四分之一行宽,长词按需占几格,同一行剩下的平分,看起来是对齐的格子。
        let cell = width / 4
        var x: CGFloat = 0, y: CGFloat = 0
        var row: [(UIButton, CGFloat)] = []
        func flush(stretch: Bool = true) {
            let used = row.reduce(0) { $0 + $1.1 }
            let extra = row.isEmpty || !stretch ? 0 : (width - used) / CGFloat(row.count)
            var cx = inset
            for (b, w) in row {
                b.frame = CGRect(x: cx, y: y, width: w + extra, height: rowH)
                cx += w + extra
            }
            row = []
            x = 0
            y += rowH
        }
        for b in scroll.subviews.compactMap({ $0 as? UIButton }) where !b.isHidden {
            let natural = b.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: rowH)).width
            let w = min(ceil(natural / cell) * cell, width)
            if x + w > width + 0.5 { flush() }
            row.append((b, w))
            x += w
        }
        if !row.isEmpty { flush(stretch: false) } // 最后一行不拉伸,一条候选不会撑满整行
        scroll.contentSize = CGSize(width: bounds.width, height: y)
    }
}
#endif
