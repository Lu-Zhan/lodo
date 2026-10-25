#if os(iOS)
import UIKit
import LodoKeyboardModel

/// ✨ 的一次回答。
public struct LodoReply {
    /// 正文。
    public var text: String
    /// 正文能不能插进输入框(是回答就能;「这个去 lodo 里做」这类说明不能)。
    public var insertable: Bool
    /// 顺带做了的事,如「已加入任务「买牛奶」,打开 lodo 后入库」。
    public var note: String?
    public var undo: (() -> Bool)?
    /// AI 反问时的候选答案,点了接着问。
    public var options: [String]
    /// 请求出错了(正文是错误说明):给「改一下再问」。
    public var failed = false
    public init(text: String, insertable: Bool, note: String? = nil, undo: (() -> Bool)? = nil, options: [String] = []) {
        self.text = text; self.insertable = insertable; self.note = note; self.undo = undo; self.options = options
    }
}

/// 键盘里 ✨ 背后要做的事,由扩展实现(要 LodoCore 和完全访问),界面这层不碰。
@MainActor
public protocol LodoServices: AnyObject {
    /// 没开「完全访问」时 ✨ 只给说明。
    var hasFullAccess: Bool { get }
    /// 一次面板会话里接着问(反问选项、追问)会带上前面几轮。
    func ask(_ question: String) async throws -> LodoReply
    /// 关掉面板:清掉这次的对话上下文。
    func endConversation()
}

/// 面板里那一个输入框背后的文字。
final class PanelDocument: TextDocument {
    var text = "" { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var contextBeforeInput: String? { text }
    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
}

/// 候选栏上面多出来的一行:[关闭] [输入框或一句话] [操作]。
final class LodoPanelRow: UIView {
    let close = UIButton(type: .system)
    private let icon = UIImageView()
    private let field = UILabel()
    private let caret = UIView()
    private let actions = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var editing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = String(localized: "关闭")
        icon.tintColor = KeyboardAppearance.accent.accent
        icon.contentMode = .center
        field.font = .systemFont(ofSize: 17)
        field.lineBreakMode = .byTruncatingHead // 打长了看的是末尾
        caret.backgroundColor = KeyboardAppearance.accent.accent
        actions.axis = .horizontal
        actions.spacing = 8
        [close, icon, field, caret, actions, spinner].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 输入态:`text` 为空时显示占位语。
    func showInput(symbol: String, text: String, placeholder: String, buttons: [UIButton]) {
        editing = true
        field.numberOfLines = 1
        field.font = .systemFont(ofSize: 17)
        field.lineBreakMode = .byTruncatingHead // 打长了看的是末尾
        icon.image = UIImage(systemName: symbol)
        field.text = text.isEmpty ? placeholder : text
        field.textColor = text.isEmpty ? .placeholderText : .label
        field.accessibilityLabel = text.isEmpty ? placeholder : text
        setButtons(buttons)
        spinner.stopAnimating()
        startCaret()
        setNeedsLayout()
    }

    /// 一句话(进行中、已保存、说明),可带按钮。
    func showMessage(symbol: String, text: String, busy: Bool = false, buttons: [UIButton] = []) {
        editing = false
        // 说明文字要从头读:最多两行,截尾巴。
        field.numberOfLines = 2
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        icon.image = UIImage(systemName: symbol)
        field.text = text
        field.textColor = .label
        field.accessibilityLabel = text
        setButtons(buttons)
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        caret.layer.removeAllAnimations()
        caret.isHidden = true
        setNeedsLayout()
    }

    private func setButtons(_ buttons: [UIButton]) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach(actions.addArrangedSubview)
    }

    private func startCaret() {
        caret.isHidden = false
        caret.layer.removeAllAnimations()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1; blink.toValue = 0
        blink.duration = 0.55; blink.autoreverses = true; blink.repeatCount = .infinity
        caret.layer.add(blink, forKey: "blink")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        close.frame = CGRect(x: 4, y: 0, width: 40, height: h)
        icon.frame = CGRect(x: 42, y: 0, width: 26, height: h)
        let actionsSize = actions.systemLayoutSizeFitting(CGSize(width: bounds.width, height: h))
        actions.frame = CGRect(x: bounds.width - actionsSize.width - 10, y: (h - 34) / 2, width: actionsSize.width, height: 34)
        let right = (actions.arrangedSubviews.isEmpty ? bounds.width - 10 : actions.frame.minX - 8)
        spinner.frame = CGRect(x: right - 24, y: 0, width: 24, height: h)
        let fieldRight = spinner.isAnimating ? spinner.frame.minX - 4 : right
        let natural = editing ? field.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: h)).width : .greatestFiniteMagnitude
        let width = min(natural, fieldRight - 74)
        field.frame = CGRect(x: 72, y: 0, width: max(width, 0), height: h)
        caret.frame = CGRect(x: field.textColor == .placeholderText ? 72 : min(field.frame.maxX + 1, fieldRight - 2),
                             y: h / 2 - 11, width: 2, height: 22)
    }

    /// 面板改色(换了强调色后重新上一遍)。
    func applyAccent() {
        icon.tintColor = KeyboardAppearance.accent.accent
        caret.backgroundColor = KeyboardAppearance.accent.accent
    }

    static func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        if prominent {
            config.baseBackgroundColor = KeyboardAppearance.accent.fill
            config.baseForegroundColor = KeyboardAppearance.accent.onFill
        }
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)]))
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }

    static func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = KeyboardAppearance.accent.fill
        config.baseForegroundColor = KeyboardAppearance.accent.onFill
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        return b
    }
}

/// ✨ 的回答:盖在键区上(键盘高度不跳),底下一排「插入 / 复制 / 撤销」,反问时是一排选项。
final class LodoReplyView: UIView {
    private let text = UITextView()
    private let note = UILabel()
    private let buttons = UIStackView()
    private let options = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isSelectable = false
        text.backgroundColor = .clear
        text.font = .systemFont(ofSize: 17)
        text.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 6, right: 12)
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabel
        note.numberOfLines = 2
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        options.showsHorizontalScrollIndicator = false
        [text, note, buttons, options].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ reply: LodoReply, actions: [UIButton], optionButtons: [UIButton]) {
        text.text = reply.text
        text.contentOffset = .zero
        note.text = reply.note
        note.isHidden = reply.note == nil
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.forEach(buttons.addArrangedSubview)
        options.subviews.forEach { $0.removeFromSuperview() }
        optionButtons.forEach(options.addSubview)
        options.isHidden = optionButtons.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, inset: CGFloat = 10
        var bottom = bounds.height - 8
        buttons.frame = CGRect(x: inset, y: bottom - 40, width: w - 2 * inset, height: 40)
        bottom = buttons.frame.minY - 6
        if !options.isHidden {
            options.frame = CGRect(x: 0, y: bottom - 36, width: w, height: 36)
            var x = inset
            for b in options.subviews {
                let bw = b.systemLayoutSizeFitting(CGSize(width: w, height: 34)).width
                b.frame = CGRect(x: x, y: 1, width: bw, height: 34)
                x += bw + 8
            }
            options.contentSize = CGSize(width: x, height: 36)
            bottom = options.frame.minY - 4
        }
        if !note.isHidden {
            let nh = note.sizeThatFits(CGSize(width: w - 24, height: 40)).height
            note.frame = CGRect(x: 12, y: bottom - nh, width: w - 24, height: nh)
            bottom = note.frame.minY - 2
        }
        text.frame = CGRect(x: 0, y: 0, width: w, height: max(bottom, 0))
    }
}
#endif
