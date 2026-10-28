#if os(iOS)
import UIKit

/// 九宫格左边那一竖条:没在拼时是常用标点,拼的时候换成「选拼音」(开头那几个数字能读成哪些拼音)。
/// 和键帽同一套底色、竖着滚,系统九宫格也是这样。
final class NineKeyColumnView: UIView {
    enum Item: Equatable {
        case punctuation(String)
        case syllable(String, length: Int)

        var title: String {
            switch self {
            case .punctuation(let s), .syllable(let s, _): s
            }
        }
    }

    var onSelect: ((Item) -> Void)?
    private let scroll = CandidateScrollView()
    private var buttons: [UIButton] = []
    private var items: [Item] = []
    /// 手指按在某一项上 / 正在拖动时来的新列表:先不换(松手就选错了),停下来再补上。同候选栏。
    private var deferred: [Item]?
    private var isInteracting: Bool {
        scroll.isInteracting || buttons.contains { !$0.isHidden && $0.isTracking }
    }
    static let rowHeight: CGFloat = 40

    /// 没在拼时的标点(中文全角)。
    static let punctuation = ["，", "。", "？", "！", "、", "：", "；", "…", "～", "“", "”"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.plainForKeyboard()
        addSubview(scroll)
        scroll.onInteractionEnded = { [weak self] in self?.applyDeferred() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [Item]) {
        if isInteracting {
            deferred = items
            return
        }
        deferred = nil
        guard items != self.items else { return }
        let changed = items.map(\.title) != self.items.map(\.title)
        self.items = items
        while buttons.count < items.count {
            let i = buttons.count
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .label
            config.contentInsets = .zero
            // 选的是按钮上正写着的那一项(列表冻结着,就是手指按下时看到的);session 那边再核对它是否仍然适用。
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self, self.items.indices.contains(i) else { return }
                self.onSelect?(self.items[i])
            })
            b.addAction(UIAction { [weak self] _ in
                DispatchQueue.main.async { self?.applyDeferred() } // 选词事件处理完再换
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
            buttons.append(b)
            scroll.addSubview(b)
        }
        for (i, b) in buttons.enumerated() {
            b.isHidden = i >= items.count
            guard i < items.count else { continue }
            let syllable: Bool = { if case .syllable = items[i] { return true }; return false }()
            b.configuration?.attributedTitle = AttributedString(items[i].title, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: syllable ? 17 : 19),
            ]))
            b.accessibilityLabel = items[i].title
        }
        if changed { scroll.contentOffset = .zero }
        setNeedsLayout()
    }

    private func applyDeferred() {
        guard let d = deferred, !isInteracting else { return }
        show(d)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = KeyboardAppearance.functionKey
        scroll.frame = bounds
        for (i, b) in buttons.enumerated() where !b.isHidden {
            b.frame = CGRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(items.count) * Self.rowHeight)
    }
}
#endif
