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
        keyboard?.willAppear()
        keyboard?.layout() // 先把高度约束挂上,键盘弹出来就是完整高度
    }

    /// 主 app 写的设置、强调色、记忆快照:扩展常驻期间可能变过,每次弹出都重读一遍(都很轻)。
    private func reloadSettings() {
        guard let keyboard else { return }
        services?.reload()
        keyboard.setFuzzy(FuzzyOptions(rawValue: KeyboardExchange.shared?.integer(forKey: KeyboardExchange.fuzzyKey) ?? 0))
        keyboard.hapticsEnabled = KeyboardExchange.shared?.object(forKey: KeyboardExchange.hapticsKey) as? Bool ?? true
        keyboard.hapticsIntensity = KeyboardExchange.hapticsIntensity(
            from: KeyboardExchange.shared?.object(forKey: KeyboardExchange.hapticsIntensityKey))
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
        keyboard?.textDidChange()
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
