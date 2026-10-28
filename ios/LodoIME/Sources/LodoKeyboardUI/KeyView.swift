#if os(iOS)
import UIKit
import LodoKeyboardModel

/// 一颗键帽。只负责画;触摸由 `KeyAreaView` 统一接管。
final class KeyView: UIView {
    let key: Key
    var onActivate: (() -> Void)?
    private let label = UILabel()
    private let imageView = UIImageView()
    /// 右上角的长按提示(「，」上的 ')。
    private let hintLabel = UILabel()
    /// 右下角的小字(空格上的「拼」)。
    private let cornerLabel = UILabel()
    private var prominent = false

    var isPressed = false { didSet { if isPressed != oldValue { applyColors() } } }

    init(key: Key) {
        self.key = key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        imageView.contentMode = .center
        imageView.tintColor = .label
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .right
        cornerLabel.font = .systemFont(ofSize: 12)
        cornerLabel.textColor = .secondaryLabel
        cornerLabel.textAlignment = .right
        addSubview(cornerLabel)
        addSubview(label)
        addSubview(imageView)
        addSubview(hintLabel)
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        // 深浅色切换时描边色要重新解析(CGColor 不会自己跟着变)。
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: KeyView, _) in
            self.applyColors()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 文字或符号图标二选一。`prominent` = 蓝底白字(回车在搜索/发送时)。
    func configure(title: NSAttributedString?, symbol: String?, font: UIFont, prominent: Bool,
                   hint: String? = nil, corner: String? = nil, accessibility: String,
                   accessibilityValue: String? = nil) {
        self.prominent = prominent
        hintLabel.text = hint
        hintLabel.isHidden = hint == nil
        cornerLabel.text = corner
        cornerLabel.isHidden = corner == nil
        // 调用方没指定字体的那几段用默认字体(「中/英」两段各有字号)。
        let text = NSMutableAttributedString(attributedString: title ?? NSAttributedString())
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: font, range: range) }
        }
        if prominent { text.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: text.length)) }
        label.textColor = .label
        label.attributedText = text
        imageView.image = symbol.map {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        } ?? nil
        imageView.tintColor = prominent ? .white : .label
        accessibilityLabel = accessibility
        self.accessibilityValue = accessibilityValue
        applyColors()
    }

    func applyColors() {
        let base: UIColor
        if prominent {
            base = isPressed ? KeyboardAppearance.characterKey : KeyboardAppearance.prominentKey
        } else if key.isFunction {
            base = isPressed ? KeyboardAppearance.characterKey : KeyboardAppearance.functionKey
        } else {
            // 字符键按下时靠放大气泡反馈,自己不变色;没有气泡的(iPad、横屏空格)才变色。
            base = isPressed && !key.showsCallout ? KeyboardAppearance.functionKey : KeyboardAppearance.characterKey
        }
        backgroundColor = base
        layer.borderWidth = KeyboardAppearance.increasesContrast ? 1 : 0
        layer.borderColor = KeyboardAppearance.keyBorder.resolvedColor(with: traitCollection).cgColor
        if KeyboardAppearance.drawsKeyShadow {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 0
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        imageView.frame = bounds
        hintLabel.frame = CGRect(x: 0, y: 2, width: bounds.width - 5, height: 13)
        cornerLabel.frame = CGRect(x: 0, y: bounds.height - 17, width: bounds.width - 7, height: 15)
    }


    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }
}

/// 字符键按下时冒出来的放大气泡:键帽向上长出一截,里面写大号字。
final class CalloutView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.25
        shape.shadowRadius = 6
        shape.shadowOffset = CGSize(width: 0, height: 2)
        label.textAlignment = .center
        label.font = KeyboardAppearance.calloutFont
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `keyFrame` 是键帽在父视图里的位置;气泡头部宽一些,贴着父视图左右边界不出界。
    func show(_ text: String, over keyFrame: CGRect, in bounds: CGRect, cornerRadius: CGFloat) {
        let headWidth = min(keyFrame.width * 1.5 + 12, keyFrame.width + 40)
        let headHeight: CGFloat = 56
        var headX = keyFrame.midX - headWidth / 2
        headX = min(max(headX, bounds.minX + 1), bounds.maxX - headWidth - 1)
        let headTop = keyFrame.minY - headHeight - 6
        frame = CGRect(x: min(headX, keyFrame.minX), y: headTop,
                       width: max(headX + headWidth, keyFrame.maxX) - min(headX, keyFrame.minX),
                       height: keyFrame.maxY - headTop)
        let ox = frame.minX, oy = frame.minY
        let head = CGRect(x: headX - ox, y: 0, width: headWidth, height: headHeight)
        let stem = CGRect(x: keyFrame.minX - ox, y: keyFrame.minY - oy, width: keyFrame.width, height: keyFrame.height)
        let path = UIBezierPath(roundedRect: head, cornerRadius: cornerRadius * 1.4)
        path.append(UIBezierPath(roundedRect: stem, cornerRadius: cornerRadius))
        // 头和键帽之间用梯形连起来。
        let neck = UIBezierPath()
        neck.move(to: CGPoint(x: head.minX, y: head.maxY - cornerRadius))
        neck.addLine(to: CGPoint(x: head.maxX, y: head.maxY - cornerRadius))
        neck.addLine(to: CGPoint(x: stem.maxX, y: stem.minY + cornerRadius))
        neck.addLine(to: CGPoint(x: stem.minX, y: stem.minY + cornerRadius))
        neck.close()
        path.append(neck)
        shape.path = path.cgPath
        shape.fillColor = KeyboardAppearance.calloutFill.resolvedColor(with: traitCollection).cgColor
        label.text = text
        label.frame = head
        isHidden = false
    }
}
#endif
