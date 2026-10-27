import LodoCore
import LodoIME
import LodoKeyboardModel
import LodoKeyboardUI
import UIKit

/// 系统键盘扩展的入口。打字逻辑都在 LodoIME 包里(LodoKeyboardModel / LodoKeyboardUI),这里只做转接。
final class KeyboardViewController: UIInputViewController, KeyboardHost {
    private var keyboard: KeyboardController?
    private var services: KeyboardLodoServices?
    private(set) lazy var document: TextDocument = ProxyDocument(controller: self)

    var returnKeyType: UIReturnKeyType { textDocumentProxy.returnKeyType ?? .default }
    var keyboardType: UIKeyboardType { textDocumentProxy.keyboardType ?? .default }
    var autocapitalizationType: UITextAutocapitalizationType { textDocumentProxy.autocapitalizationType ?? .sentences }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 用户词存扩展自己的容器:不需要「完全访问」,也不和主 app 共享。
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "LodoIME/user-dictionary.json")
        do {
            let keyboard = try KeyboardController(host: self, userDictionaryURL: url)
            self.keyboard = keyboard
            // 根视图摆进系统给的 inputView 里、四边钉住,而不是直接替换掉 inputView:
            // 替换掉的话系统只在弹出时问一次高度,打开 ✨ 栏后键盘长不高(真机实测);
            // 作为子视图时它的 intrinsicContentSize / 高度约束一变,系统就跟着重新定键盘高度。
            let root = keyboard.rootView
            inputView?.allowsSelfSizing = true
            root.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(root)
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                root.topAnchor.constraint(equalTo: view.topAnchor),
                root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            let services = KeyboardLodoServices(controller: self)
            self.services = services
            keyboard.services = services
        } catch {
            assertionFailure("词库载入失败:\(error)")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSettings()
        followHostAppearance()
        keyboard?.willAppear()
        keyboard?.layout() // 先把高度约束挂上,键盘弹出来就是完整高度
    }

    /// 主 app 写的设置、强调色、记忆快照:扩展常驻期间可能变过,每次弹出都重读一遍(都很轻)。
    private func reloadSettings() {
        guard let keyboard else { return }
        services?.reload()
        keyboard.loadPersonalDictionary(from: KeyboardExchange.personalWordsURL)
        keyboard.setFuzzy(FuzzyOptions(rawValue: KeyboardExchange.shared?.integer(forKey: KeyboardExchange.fuzzyKey) ?? 0))
        keyboard.setSmartCorrection(KeyboardExchange.shared?.object(forKey: KeyboardExchange.smartCorrectionKey) as? Bool ?? true)
        keyboard.hapticsEnabled = KeyboardExchange.shared?.object(forKey: KeyboardExchange.hapticsKey) as? Bool ?? true
        keyboard.nineKey = KeyboardExchange.shared?.bool(forKey: KeyboardExchange.nineKeyKey) ?? false
        keyboard.hapticsStyle = switch KeyboardExchange.hapticsStyle(from: KeyboardExchange.shared?.object(forKey: KeyboardExchange.hapticsStyleKey)) {
        case .crisp: .rigid
        case .standard: .light
        case .soft: .soft
        }
        keyboard.hapticsIntensity = KeyboardExchange.hapticsIntensity(
            from: KeyboardExchange.shared?.object(forKey: KeyboardExchange.hapticsIntensityKey))
        keyboard.keyHeightScale = CGFloat(KeyboardExchange.keyHeightScale(
            from: KeyboardExchange.shared?.object(forKey: KeyboardExchange.keyHeightScaleKey)))
        if let theme = KeyboardExchange.loadTheme() {
            let accent = KeyboardAccent.dynamic(light: theme.accentLight, dark: theme.accentDark)
            keyboard.accent = KeyboardAccent(
                accent: accent,
                fill: theme.fillLight.flatMap { light in theme.fillDark.map { KeyboardAccent.dynamic(light: light, dark: $0) } } ?? accent,
                onFill: theme.onFillLight.flatMap { light in theme.onFillDark.map { KeyboardAccent.dynamic(light: light, dark: $0) } } ?? .white)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboard?.willDisappear()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyboard?.layout()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        followHostAppearance()
        keyboard?.textDidChange()
    }

    /// 深浅色同系统键盘:输入框指定了 `keyboardAppearance`(深色主题的 app 在浅色模式下也要深色键盘)就照它,
    /// 没指定才跟系统。系统按它画背板,键帽不跟着走的话浅色键帽会压在深色背板上。切换输入框时可能变,所以每次回调都看一眼。
    private func followHostAppearance() {
        let style: UIUserInterfaceStyle = switch textDocumentProxy.keyboardAppearance {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
        if view.overrideUserInterfaceStyle != style { view.overrideUserInterfaceStyle = style }
    }

    func moveCursor(by offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    func attachInputModeSwitch(to button: UIButton) {
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    }
}

private final class ProxyDocument: TextDocument {
    unowned let controller: UIInputViewController
    init(controller: UIInputViewController) { self.controller = controller }
    var contextBeforeInput: String? { controller.textDocumentProxy.documentContextBeforeInput }
    func insertText(_ text: String) { controller.textDocumentProxy.insertText(text) }
    func deleteBackward() { controller.textDocumentProxy.deleteBackward() }
    /// 拼音写成输入框里的标记文字(带下划线),同系统拼音键盘;光标放在末尾。
    var supportsMarkedText: Bool { true }
    func setMarkedText(_ text: String) {
        controller.textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }
    func unmarkText() { controller.textDocumentProxy.unmarkText() }
}
