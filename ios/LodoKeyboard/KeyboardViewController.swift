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
            keyboard.onUserDictionarySaved = { [weak self] in self?.exportFrequentWords() }
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
        lastDocumentIdentifier = textDocumentProxy.documentIdentifier
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
        keyboard.learnsWords = KeyboardExchange.shared?.object(forKey: KeyboardExchange.learnWordsKey) as? Bool ?? true
        applyFrequentWordEdits()
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

    // MARK: - 常用词

    /// 处理到哪一条主 app 的整理(存扩展自己的 standard:没开完全访问时 App Group 写不进去)。
    private static let appliedEditsKey = "frequentWordsAppliedSerial"
    private var appliedEditSerial: Int {
        get { UserDefaults.standard.integer(forKey: Self.appliedEditsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.appliedEditsKey) }
    }

    /// 主 app「常用词」页里删的、固定的、清空的:每次弹出时补做还没做过的那几条。
    private func applyFrequentWordEdits() {
        guard let keyboard else { return }
        let pending = KeyboardExchange.pendingFrequentWordEdits(after: appliedEditSerial)
        if let last = pending.last {
            keyboard.apply(pending.map { edit in
                let ids = edit.ids.compactMap { UInt16(exactly: $0) }
                return switch edit.kind {
                case .forget: .forget(edit.word, ids: ids)
                case .pin: .pin(edit.word, ids: ids, true)
                case .unpin: .pin(edit.word, ids: ids, false)
                case .clearAll: .clearAll
                }
            })
            appliedEditSerial = last.serial // apply 会落盘,落盘后再导出
        } else if KeyboardExchange.loadFrequentWords() == nil {
            exportFrequentWords() // 第一次开完全访问:先给主 app 一份
        }
    }

    /// 把最常用的那些导出给主 app 的整理页。要「允许完全访问」才写得进 App Group,没开就不做。
    private func exportFrequentWords() {
        guard hasFullAccess, let keyboard else { return }
        let dictionary = keyboard.userDictionary
        let names = keyboard.syllableNames
        let applied = appliedEditSerial
        Task.detached(priority: .utility) {
            let words = dictionary.entries(limit: KeyboardExchange.frequentWordsLimit).map { entry in
                KeyboardExchange.FrequentWord(
                    word: entry.word,
                    pinyin: entry.ids.map { names.indices.contains(Int($0)) ? names[Int($0)] : "?" }.joined(separator: " "),
                    ids: entry.ids.map(Int.init), weight: entry.weight, lastUsed: entry.lastUsed, pinned: entry.pinned)
            }
            KeyboardExchange.writeFrequentWords(.init(exportedAt: Date(), words: words, appliedSerial: applied))
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
        // 换了输入框:上一框没上屏的拼音作废(新框光标前可能碰巧也是空的,回声判断分不出来)。
        let identifier = textDocumentProxy.documentIdentifier
        let newDocument = lastDocumentIdentifier != nil && lastDocumentIdentifier != identifier
        lastDocumentIdentifier = identifier
        keyboard?.textDidChange(newDocument: newDocument)
    }
    private var lastDocumentIdentifier: UUID?

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
