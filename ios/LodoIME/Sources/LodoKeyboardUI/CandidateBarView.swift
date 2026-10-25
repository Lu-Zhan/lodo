#if os(iOS)
import UIKit
import LodoIME

/// 候选栏里的一项,连同点了之后做什么(按钮记着它本身,不记下标)。
enum CandidateChoice: Equatable {
    /// 拼音候选;`key` 是它解出来时的拼音。
    case candidate(Candidate, key: String)
    /// 原样字母(灰字那一项)。
    case raw(String)
    /// 英文补全。
    case suggestion(String)

    var title: String {
        switch self {
        case .candidate(let c, _): c.text
        case .raw(let s), .suggestion(let s): s
        }
    }
}

@MainActor
protocol CandidateBarDelegate: AnyObject {
    func candidateBar(select choice: CandidateChoice)
    func candidateBarToggleExpanded()
    func candidateBarAsk()
}

/// 候选栏的滚动视图。UIScrollView 默认先扣住触摸 150ms 看是不是要滚,快点候选时这一下会被吞掉、
/// 要再点一次(真机反馈)。这里不扣:手指落下立刻交给候选按钮;真横着拖起来了再把按钮那一下取消、改成滚动。
final class CandidateScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
        canCancelContentTouches = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// UIControl 默认不让滚动视图取消,那样按在候选上就拖不动整排了。
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// 候选按钮池:每敲一个字母候选都会全换,按钮复用,不每次新建几十个视图。
@MainActor
final class CandidateButtons {
    private var pool: [UIButton] = []
    private let action: (Int) -> Void
    /// 手指离开候选(选中、拖走、取消)时调:按着的时候候选栏不换内容,松手后补上。
    var onTrackingEnded: (() -> Void)?

    init(action: @escaping (Int) -> Void) { self.action = action }

    /// 有没有手指正按在某个候选上。
    var isTracking: Bool { pool.contains { !$0.isHidden && $0.isTracking } }

    func buttons(count: Int, in container: UIView) -> [UIButton] {
        while pool.count < count {
            let i = pool.count
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 11.5, bottom: 0, trailing: 11.5) // 候选之间约 23pt,同系统
            config.baseForegroundColor = .label
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.action(i) })
            b.addAction(UIAction { [weak self] _ in
                // 放到下一轮:先让这次选词(primaryAction)跑完,再补上按着时攒下的候选。
                DispatchQueue.main.async { self?.onTrackingEnded?() }
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
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

    static func set(_ b: UIButton, _ text: String, secondary: Bool = false, topInset: CGFloat = 0) {
        // 首选不加粗,靠底下那块圆角底标出来(同系统)。
        b.configuration?.attributedTitle = AttributedString(text, attributes: AttributeContainer([
            .font: KeyboardAppearance.candidateFont,
        ]))
        b.configuration?.baseForegroundColor = secondary ? .secondaryLabel : .label
        b.configuration?.contentInsets.top = topInset
        b.accessibilityLabel = text
    }
}

/// 键区上方那一条:正在拼时是「横排候选(首选垫一块圆角底)+ 展开键」,没在拼时左边一颗 ✨。
/// 拼音写在宿主输入框里(标记文字),这里不再单列一行;宿主不支持时才退回上面一行小字。
final class CandidateBarView: UIView {
    weak var delegate: CandidateBarDelegate?
    private let preedit = UILabel()
    private let scroll = CandidateScrollView()
    private lazy var buttons: CandidateButtons = {
        let b = CandidateButtons { [weak self] i in
            guard let self, self.choices.indices.contains(i) else { return }
            self.delegate?.candidateBar(select: self.choices[i])
        }
        b.onTrackingEnded = { [weak self] in self?.flushDeferred() }
        return b
    }()
    /// 手指按在候选上时来了新内容:先攒着,松手再换(不然按着的那颗按钮会变成别的词、或被挪走)。
    private var deferred: (preedit: String?, composing: Bool, choices: [CandidateChoice], secondary: Int?)?
    /// 按钮 i 点了选的就是 `choices[i]`,和它显示的字永远是同一份。
    private var choices: [CandidateChoice] = []
    private let expand = UIButton(type: .system)
    private let ask = UIButton(type: .system)
    private let divider = UIView()
    /// 首选底下那块圆角底(同系统:36pt 高,比候选字两边各宽 5pt)。
    private let highlight = UIView()
    private var composing = false
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
        scroll.plainForKeyboard()
        highlight.isUserInteractionEnabled = false
        highlight.layer.cornerRadius = 9
        highlight.layer.cornerCurve = .continuous
        scroll.addSubview(highlight)
        var expandConfig = UIButton.Configuration.plain()
        expandConfig.image = UIImage(systemName: "chevron.down")
        expandConfig.baseForegroundColor = .label
        expand.configuration = expandConfig
        expand.accessibilityLabel = String(localized: "更多候选")
        expand.addAction(UIAction { [weak self] _ in self?.delegate?.candidateBarToggleExpanded() }, for: .touchUpInside)
        // 和键帽上的字同色(深色下是白色),不跟强调色。
        ask.tintColor = .label
        ask.setImage(UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        ask.accessibilityLabel = String(localized: "问 lodo")
        ask.addAction(UIAction { [weak self] _ in self?.delegate?.candidateBarAsk() }, for: .touchUpInside)
        divider.backgroundColor = .separator
        [preedit, scroll, expand, ask, divider].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 拼音那一行的高度;候选按钮的可点范围铺满整栏(含这一行),字画在它下面。
    static let preeditStrip: CGFloat = 20

    /// `preedit` 为 nil = 没在拼(英文补全也走这里,只是不显示拼音行)。
    /// `secondaryIndex`:画成灰字的那一项(原样字母)。
    private var shown: (preedit: String?, secondary: Int?, lodo: Bool, composing: Bool)?

    func show(preedit text: String?, composing: Bool, choices: [CandidateChoice], secondaryIndex: Int? = nil) {
        if buttons.isTracking {
            deferred = (text, composing, choices, secondaryIndex)
            return
        }
        deferred = nil
        // 字一样也要换上新的绑定(同一个字可能吃掉的拼音不同)。
        self.choices = choices
        let items = choices.map(\.title)
        let changed = items != self.items
        // 内容一模一样(宿主回调、选词后的重复刷新)就什么都不动:候选按钮的配置和逐个量宽度都不便宜。
        if !changed, let s = shown, s.preedit == text, s.secondary == secondaryIndex, s.lodo == showsLodoKeys,
           s.composing == composing { return }
        shown = (text, secondaryIndex, showsLodoKeys, composing)
        self.composing = composing
        self.items = items
        preedit.text = text
        preedit.isHidden = text == nil
        let strip = text == nil ? 0 : Self.preeditStrip
        let visible = Array(items.prefix(Self.inlineLimit))
        let bs = buttons.buttons(count: visible.count, in: scroll)
        for (i, b) in bs.enumerated() {
            CandidateButtons.set(b, visible[i], secondary: i == secondaryIndex, topInset: strip)
        }
        // 只有候选真的换了才滚回开头(布局回调也会走到这里,不能把用户翻到一半的候选拉回去)。
        if changed { scroll.contentOffset = .zero }
        expand.isHidden = items.count <= 1
        divider.isHidden = expand.isHidden
        ask.isHidden = !items.isEmpty || !showsLodoKeys
        setNeedsLayout()
    }

    private func flushDeferred() {
        guard let d = deferred, !buttons.isTracking else { return }
        show(preedit: d.preedit, composing: d.composing, choices: d.choices, secondaryIndex: d.secondary)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 候选栏压得很矮(键盘总高由系统定,省下来的给按键),拼音那行 20pt;
        // 但候选和展开键的可点范围是整栏高度,快速选词不至于点空。
        let strip: CGFloat = preedit.isHidden ? 0 : Self.preeditStrip
        preedit.frame = CGRect(x: 12, y: 0, width: bounds.width - 24, height: strip)
        let side: CGFloat = 44
        let rowH = bounds.height
        // 箭头和候选字对齐(画在拼音行下面);按钮内边距在这里改不及时生效,直接挪按钮。
        expand.frame = CGRect(x: bounds.width - side, y: strip, width: side, height: rowH - strip)
        divider.frame = CGRect(x: bounds.width - side, y: strip + (rowH - strip) * 0.25,
                               width: 1 / max(traitCollection.displayScale, 1), height: (rowH - strip) * 0.5)
        ask.frame = CGRect(x: 4, y: 0, width: side, height: bounds.height)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width - (expand.isHidden ? 0 : side), height: rowH)
        var x: CGFloat = 0
        var first: CGRect?
        for b in scroll.subviews.compactMap({ $0 as? UIButton }) where !b.isHidden {
            let w = max(b.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: rowH)).width, 40)
            b.frame = CGRect(x: x, y: 0, width: w, height: rowH)
            if first == nil { first = b.frame }
            x += w
        }
        scroll.contentSize = CGSize(width: x, height: rowH)
        if composing, let f = first {
            let h = min(36, rowH - strip - 4)
            highlight.frame = CGRect(x: f.minX + 6.5, y: strip + (rowH - strip - h) / 2, width: f.width - 13, height: h)
            highlight.backgroundColor = KeyboardAppearance.characterKey // 同键帽底色;「减弱透明度」切换后跟着变
            highlight.isHidden = false
        } else {
            highlight.isHidden = true
        }
    }
}

/// 展开后的全部候选:盖在键区上,自动换行,竖着滚。
final class CandidateGridView: UIView {
    var onSelect: ((CandidateChoice) -> Void)?
    private let scroll = CandidateScrollView()
    private lazy var buttons: CandidateButtons = {
        let b = CandidateButtons { [weak self] i in
            guard let self, self.choices.indices.contains(i) else { return }
            self.onSelect?(self.choices[i])
        }
        b.onTrackingEnded = { [weak self] in
            guard let self, let d = self.deferred, !self.buttons.isTracking else { return }
            self.show(d.choices, resetScroll: d.reset)
        }
        return b
    }()
    private var items: [String] = []
    private var choices: [CandidateChoice] = []
    /// 同横排候选栏:按着某个候选时不换内容,松手再补上。
    private var deferred: (choices: [CandidateChoice], reset: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.alwaysBounceVertical = true
        scroll.plainForKeyboard()
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `resetScroll`:刚展开时回到顶上;之后的刷新(布局回调)只有候选真的变了才回去。
    func show(_ choices: [CandidateChoice], resetScroll: Bool = false) {
        if buttons.isTracking {
            deferred = (choices, resetScroll || deferred?.reset == true)
            return
        }
        deferred = nil
        self.choices = choices
        let items = choices.map(\.title)
        let changed = items != self.items
        if !changed && !resetScroll { return }
        self.items = items
        let bs = buttons.buttons(count: items.count, in: scroll)
        for (i, b) in bs.enumerated() { CandidateButtons.set(b, items[i]) }
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
