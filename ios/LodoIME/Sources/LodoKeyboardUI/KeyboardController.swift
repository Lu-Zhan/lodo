#if os(iOS)
import UIKit
import LodoIME
import LodoKeyboardModel
import LodoReranker

/// 键盘挂在谁身上:扩展里是 `UIInputViewController`,截图用的 demo app 里是一个假的宿主。
@MainActor
public protocol KeyboardHost: AnyObject {
    var document: TextDocument { get }
    var needsInputModeSwitchKey: Bool { get }
    var returnKeyType: UIReturnKeyType { get }
    var keyboardType: UIKeyboardType { get }
    var autocapitalizationType: UITextAutocapitalizationType { get }
    func moveCursor(by offset: Int)
    func dismissKeyboard()
    /// 地球键:扩展里接到 `handleInputModeList(from:with:)`。
    func attachInputModeSwitch(to button: UIButton)
}

/// 根视图。`.keyboard` 样式让系统画键盘背板;遵守 `UIInputViewAudioFeedback` 才能放系统按键音。
public final class KeyboardRootView: UIInputView, UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }

    /// 想要的高度。`allowsSelfSizing` 开着时系统按 `intrinsicContentSize` 定键盘高度
    /// (只加高度约束不够:真机上系统照样按默认高度摆,最下面一行被截掉)。
    var desiredHeight: CGFloat = 0 {
        didSet { if desiredHeight != oldValue { invalidateIntrinsicContentSize() } }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight)
    }
}

/// 英文补全接系统拼写检查器。
struct TextCheckerCompleter: EnglishCompleter {
    let checker = UITextChecker()
    func completions(for word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let found = checker.completions(forPartialWordRange: range, in: word, language: "en_US") ?? []
        // 第一格永远是原样的字母,和系统 QuickType 一样。
        return [word] + found.filter { $0.lowercased() != word.lowercased() }.map {
            word.first?.isUppercase == true ? $0.prefix(1).uppercased() + $0.dropFirst() : $0
        }
    }
}

/// 用户词落盘:串行写,旧版本不会盖掉新版本。
actor UserDictionarySaver {
    private var written = 0

    func save(_ dict: UserDictionary, version: Int, to url: URL) -> Bool {
        guard version > written else { return true }
        do {
            let data = try JSONEncoder().encode(dict)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written = version
            return true
        } catch {
            return false
        }
    }
}

@MainActor
public final class KeyboardController: NSObject {
    public let rootView = KeyboardRootView(frame: CGRect(x: 0, y: 0, width: 390, height: 280), inputViewStyle: .keyboard)
    public let session: TypingSession
    private weak var host: KeyboardHost?
    private let bar = CandidateBarView()
    private let keys = KeyAreaView()
    private let grid = CandidateGridView()
    /// 九宫格左边那一竖条(标点 / 选拼音)。
    private let nineColumn = NineKeyColumnView()
    /// 中文用九宫格(主 app 设置「中文键盘」);英文和 123 页照旧全键盘。
    public var nineKey = false {
        didSet { if nineKey != oldValue { keyFaceState = nil; render() } }
    }
    private var usesNineKey: Bool { nineKey && session.language == .chinese && session.page == .letters }
    /// 横竖屏/设备决定的「按键弹气泡」;九宫格的大键不弹。
    private var calloutsAllowed = true
    private let panelRow = LodoPanelRow()
    private let replyView = LodoReplyView()
    private let panelDocument = PanelDocument()
    private var heightConstraint: NSLayoutConstraint?

    /// lodo 的强调色,扩展按主 app 的设置给。
    public var accent: KeyboardAccent {
        get { KeyboardAppearance.accent }
        set {
            KeyboardAppearance.accent = newValue
            panelRow.applyAccent()
            renderPanel()
        }
    }

    /// 按键震动(主 app 设置里的开关)。系统只在开了「完全访问」时才让键盘扩展震动,没开时这是空操作。
    public var hapticsEnabled: Bool {
        get { haptics.enabled }
        set { haptics.enabled = newValue }
    }
    /// 震动强度(0.1…1.0),主 app 设置里的滑块。
    public var hapticsIntensity: Double {
        get { Double(haptics.intensity) }
        set { haptics.intensity = CGFloat(newValue) }
    }
    /// 震感(主 app 设置里的「清脆 / 标准 / 柔和」)。
    public var hapticsStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        get { haptics.style }
        set { haptics.style = newValue }
    }
    private let haptics = KeyboardHaptics()

    /// 按键高度倍数(主 app 设置里的滑块):只乘键帽高度,候选栏、键缝、行距不变。
    public var keyHeightScale: CGFloat = 1 {
        didSet { if keyHeightScale != oldValue { layout() } }
    }

    /// ✨ 背后的实现;nil = 不显示这颗键(截图 demo 可以给假的)。
    public weak var services: LodoServices? { didSet { render() } }

    private enum Panel {
        case closed
        /// 正在输入问题,打的字进面板里的输入框。
        case ask
        case thinking(String)
        case reply(question: String, LodoReply)
        /// 一句话(要开完全访问)。
        case notice
    }
    private var panel = Panel.closed
    private var askTask: Task<Void, Never>?
    /// ✨ 那一栏:打开时整个键盘增高这么多(候选栏和键区不压缩);里面三块控件 32pt 高,上下各留 2pt。
    static let panelHeight: CGFloat = 36
    private var panelVisible: Bool { if case .closed = panel { false } else { true } }
    /// 面板拿着输入:写问题时,以及等回答时(这时打字 = 取消这次、接着改问题)。
    private var panelEditing: Bool {
        switch panel { case .ask, .thinking: true; default: false }
    }
    private let userDictionaryURL: URL?
    /// 用户词每变一次加一;只有对应版本真写进去了才算存过(失败下次再试)。
    private var dictionaryVersion = 0
    private var savedVersion = 0
    private var saveTimer: Timer?
    private let saver = UserDictionarySaver()
    private let decoder: BackgroundDecoder
    private var personalLoadVersion = 0
    /// 常驻最上层的地球键(位置跟着键区里那颗走),见 `KeyAreaView.globeFrame`。
    private let globeButton = UIButton(type: .custom)

    /// `userDictionaryURL`:用户词存哪(扩展自己的容器,不需要完全访问)。nil = 不持久化。
    public init(host: KeyboardHost, userDictionaryURL: URL?) throws {
        self.host = host
        self.userDictionaryURL = userDictionaryURL
        var dict = UserDictionary()
        if let url = userDictionaryURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(UserDictionary.self, from: data) {
            dict = saved
        }
        let engine = PinyinEngine(lexicon: try Lexicon.bundled(), userDictionary: dict)
        session = TypingSession(engine: engine)
        // 解码在后台做,按键不等它(主线程那份引擎只管组合态和用户词学习)。
        decoder = BackgroundDecoder(lexicon: engine.lexicon, userDictionary: dict)
        super.init()
        session.decoder = decoder
        session.document = host.document
        session.completer = TextCheckerCompleter()
        session.onChange = { [weak self] in self?.render() }
        // 模型 5 MB,读进来要几十毫秒,别挡键盘出现;载入前照样能打字,只是没有重排。
        Task.detached(priority: .userInitiated) {
            let model = ModelReranker.bundled()
            await MainActor.run { [weak self] in self?.decoder.setReranker(model) }
        }

        // 扩展里根视图四边钉在系统给的 inputView 上(见 KeyboardViewController),这里只加一条高度约束。
        // 别把根视图直接当 inputView 再关 translatesAutoresizingMaskIntoConstraints:那样系统给它的尺寸会塌成很小,
        // 键帽照样画出来,但触摸只送到根视图范围内,一颗都点不到(真机实测)。
        rootView.allowsSelfSizing = true
        bar.delegate = self
        keys.delegate = self
        grid.isHidden = true
        grid.onSelect = { [weak self] in self?.selectCandidate($0) }
        panelRow.isHidden = true
        replyView.isHidden = true
        panelRow.close.addAction(UIAction { [weak self] _ in self?.closePanel() }, for: .touchUpInside)
        panelDocument.onChange = { [weak self] in self?.renderPanel() }
        // 键区在候选栏之上:放大气泡要盖住候选栏;地球键在最上面,展开候选、看回答时也点得到。
        globeButton.isHidden = true
        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .clear // 键帽在键区里画,这颗只负责接触摸;键区藏起来时才露出图标
        globeButton.accessibilityLabel = String(localized: "下一个键盘")
        nineColumn.isHidden = true
        nineColumn.onSelect = { [weak self] item in
            guard let self else { return }
            self.haptics.play(.key)
            switch item {
            case .punctuation(let p): self.keyArea(trigger: .text(p))
            case .syllable(let s, let length): self.session.fixSpelling(s, length: length)
            }
        }
        [panelRow, bar, keys, nineColumn, grid, replyView, globeButton].forEach(rootView.addSubview)
        host.attachInputModeSwitch(to: globeButton)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged),
                                               name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
    }

    // MARK: - 宿主转来的事件

    /// 宿主输入框换了属性(回车键类型、键盘类型):扩展里在 `textDidChange` 调。
    public func textDidChange() {
        session.autocapitalization = switch host?.autocapitalizationType {
        case .none?: .none
        case .words?: .words
        case .allCharacters?: .allCharacters
        default: .sentences
        }
        // 面板在输入时打的字不在宿主里,宿主那边的变化(含迟到的回调)和面板里的组合无关。
        if !panelEditing { session.documentChanged() }
    }

    /// 键盘出现时:邮箱、网址这类输入框直接从英文开始。
    public func willAppear() {
        if let type = host?.keyboardType, [.emailAddress, .URL, .asciiCapable, .webSearch].contains(type),
           session.language == .chinese {
            session.handle(.toggleLanguage)
        }
        textDidChange()
        haptics.prepare()
    }

    /// 键盘收起:没选的拼音原样留在输入框里,用户词落盘。
    public func willDisappear() {
        closePanel()
        session.commitRaw()
        saveUserDictionary()
    }

    /// 扩展常驻期间主 app 可能改了设置:每次弹出键盘时由扩展调。
    public func setFuzzy(_ options: FuzzyOptions) {
        guard session.engine.fuzzy != options else { return }
        session.engine.fuzzy = options
        decoder.setFuzzy(options)
        session.personalDictionaryChanged()
    }

    public func setSmartCorrection(_ enabled: Bool) {
        guard session.engine.correctionEnabled != enabled else { return }
        session.engine.correctionEnabled = enabled
        decoder.setCorrectionEnabled(enabled)
        session.personalDictionaryChanged()
    }

    /// 主 app 的姓名快照可能较大,文件读取和建索引都不占用触摸线程。
    public func loadPersonalDictionary(from url: URL?) {
        personalLoadVersion += 1
        let version = personalLoadVersion
        let lexicon = session.engine.lexicon
        Task.detached(priority: .utility) { [weak self] in
            let words: [PersonalDictionary.Word]
            if let url {
                // 损坏/暂不可读时保持旧索引;空词库也会写成有效快照。
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(PersonalDictionary.Snapshot.self, from: data),
                      snapshot.version == 1 else { return }
                words = snapshot.words
            } else {
                words = []
            }
            let dictionary = PersonalDictionary(words: words, lexicon: lexicon)
            await MainActor.run { [weak self] in
                guard let self, self.personalLoadVersion == version else { return }
                self.session.engine.personalDictionary = dictionary
                self.decoder.setPersonalDictionary(dictionary)
                self.session.personalDictionaryChanged()
            }
        }
    }

    public func layout() {
        let pad = rootView.traitCollection.userInterfaceIdiom == .pad
        let landscape = !pad && rootView.traitCollection.verticalSizeClass == .compact
        var m: KeyboardMetrics = pad ? .pad : landscape ? .phoneLandscape : .phonePortrait
        m.keyHeight = (m.keyHeight * keyHeightScale).rounded()
        calloutsAllowed = !pad && !landscape
        let top = panelVisible ? Self.panelHeight : 0
        let total = top + m.candidateBarHeight + m.keyAreaHeight(rows: 4)
        rootView.desiredHeight = total
        // 兜底:系统给的高度还是不够时,压扁键帽把四行都摆进去,而不是让最下面一行被截掉。
        let available = rootView.bounds.height
        if available > 0, available < total - 0.5 {
            let fixed = top + m.candidateBarHeight + m.topInset + m.bottomInset + 3 * m.rowSpacing
            m.keyHeight = max((available - fixed) / 4, 28)
        }
        keys.metrics = m
        let keyHeight = m.keyAreaHeight(rows: 4)
        if heightConstraint == nil {
            let c = rootView.heightAnchor.constraint(equalToConstant: total)
            // 999:高过系统默认的键盘高度约束(750 那档压不过它,键盘会被截短),
            // 又不是 required,旋转等过渡时和系统的约束暂时冲突不会报错。
            c.priority = UILayoutPriority(999)
            c.isActive = true
            heightConstraint = c
        }
        heightConstraint?.constant = total
        let w = rootView.bounds.width
        panelRow.frame = CGRect(x: 0, y: 0, width: w, height: Self.panelHeight)
        bar.frame = CGRect(x: 0, y: top, width: w, height: m.candidateBarHeight)
        keys.frame = CGRect(x: 0, y: top + m.candidateBarHeight, width: w, height: keyHeight)
        grid.frame = keys.frame
        replyView.frame = CGRect(x: 0, y: top, width: w, height: m.candidateBarHeight + keyHeight)
        render()
    }

    // MARK: - 画

    /// 键帽长什么样只取决于这几样。打拼音时它们都不变,不必每个字母都把三十多颗键帽重新配一遍。
    private struct KeyFaceState: Equatable {
        var page: KeyboardPage
        var language: InputLanguage
        var shift: ShiftState
        var needsGlobe: Bool
        var returnKeyType: UIReturnKeyType
        var width: CGFloat
        var keyHeight: CGFloat
        var nineKey: Bool
        /// 九宫格的 1 键在拼的时候写「分词」、平时写「@/.」;「重输」平时变淡。
        var nineKeyComposing: Bool
    }
    private var keyFaceState: KeyFaceState?
    private var shownCompositionKey: String?

    private func render() {
        guard keys.bounds.width > 0 else { return }
        let needsGlobe = host?.needsInputModeSwitchKey ?? false
        let state = KeyFaceState(page: session.page, language: session.language, shift: session.shift,
                                 needsGlobe: needsGlobe, returnKeyType: host?.returnKeyType ?? .default,
                                 width: keys.bounds.width, keyHeight: keys.metrics.keyHeight,
                                 nineKey: usesNineKey, nineKeyComposing: usesNineKey && session.isComposing)
        keys.showsCallouts = calloutsAllowed && !usesNineKey
        if state != keyFaceState {
            keyFaceState = state
            if usesNineKey {
                let layout = KeyboardFrames.placeNineKey(width: keys.bounds.width, metrics: keys.metrics, needsGlobe: needsGlobe)
                keys.setPlaced(layout.keys) { [unowned self] in face(for: $0) }
                nineColumn.frame = layout.listFrame.offsetBy(dx: keys.frame.minX, dy: keys.frame.minY)
                nineColumn.layer.cornerRadius = keys.metrics.cornerRadius
            } else {
                let rows = KeyboardLayout.rows(page: session.page, language: session.language, needsGlobe: needsGlobe)
                keys.setRows(rows) { [unowned self] in face(for: $0) }
            }
        }
        if usesNineKey {
            nineColumn.show(session.isComposing
                ? session.nineKeySyllables.map { .syllable($0.syllable, length: $0.length) }
                : NineKeyColumnView.punctuation.map { .punctuation($0) })
        }
        bar.showsLodoKeys = services != nil && !panelVisible
        let items = displayedChoices()
        let key = session.isComposing ? session.composition.remaining : nil
        let newInput = key != shownCompositionKey
        shownCompositionKey = key
        if session.isComposing {
            bar.show(preedit: session.showsPreeditInBar ? session.preedit : nil, composing: true,
                     choices: items, secondaryIndex: rawCandidateIndex, resetScrollOnChange: newInput)
        } else {
            bar.show(preedit: nil, composing: false, choices: items, resetScrollOnChange: newInput)
        }
        if items.isEmpty { setExpanded(false) } else if !grid.isHidden { grid.show(items, resetScroll: newInput) }
        placeGlobe()
    }

    /// 中文候选优先;原样字母保留在前三个中文候选后面。
    private var rawCandidateIndex: Int? {
        // 九宫格按的是数字,「原样字母」没有意义,不给这一项。
        session.isComposing && !session.composition.remaining.isEmpty && !session.candidates.isEmpty
            && !session.composition.hasNineKeyDigits ? min(3, session.candidates.count) : nil
    }

    /// 候选栏里的每一项,连同点了之后做什么。按钮记着的是这一项本身而不是下标:
    /// 后台解码回来、按着候选时候选栏不换,下标对到的可能已经是另一份候选。
    private func displayedChoices() -> [CandidateChoice] {
        guard session.isComposing else { return session.suggestions.map { .suggestion($0) } }
        let key = session.candidatesDecodedFor ?? session.composition.remaining
        var items: [CandidateChoice] = session.candidates.map { .candidate($0, key: key) }
        if let raw = rawCandidateIndex { items.insert(.raw(session.rawLetters), at: raw) }
        return items
    }

    private func placeGlobe() {
        nineColumn.isHidden = !usesNineKey || keys.isHidden
        if let frame = keys.globeFrame {
            globeButton.frame = keys.convert(frame, to: rootView)
            globeButton.isHidden = false
            // 键区藏起来(展开候选、看回答)时,自己露出图标。
            globeButton.tintColor = keys.isHidden ? .label : .clear
            rootView.bringSubviewToFront(globeButton)
        } else {
            globeButton.isHidden = true
        }
    }

    private func face(for key: Key) -> KeyFace {
        let pad = rootView.traitCollection.userInterfaceIdiom == .pad
        let zh = session.language == .chinese
        func text(_ s: String, _ font: UIFont = KeyboardAppearance.functionFont) -> KeyFace {
            KeyFace(title: NSAttributedString(string: s), font: font, accessibility: s)
        }
        switch key.action {
        case .letter(let c) where NineKey.letters[c] != nil:
            // 九宫格的数字键:写这个键上的字母(ABC),同系统。
            return text(NineKey.letters[c]!.uppercased(), .systemFont(ofSize: 20, weight: .regular))
        case .nineKeyOne:
            return text(session.isComposing ? "分词" : "@/.", .systemFont(ofSize: session.isComposing ? 16 : 20))
        case .clearComposition:
            var f = text("重输")
            if !session.isComposing {
                f.title = NSAttributedString(string: "重输", attributes: [.foregroundColor: UIColor.tertiaryLabel])
            }
            return f
        case .letter(let c):
            let upper = session.shift != .off
            return text(upper ? c.uppercased() : String(c), KeyboardAppearance.letterFont(pad: pad))
        case .text(let t):
            return text(t, KeyboardAppearance.symbolFont)
        case .shift:
            let symbol = switch session.shift { case .off: "shift"; case .once: "shift.fill"; case .locked: "capslock.fill" }
            return KeyFace(symbol: symbol, font: KeyboardAppearance.functionFont, accessibility: String(localized: "大写"))
        case .deleteWord, .separator:
            return text("") // 只作长按/连删的动作,不会画成键帽
        case .delete:
            return KeyFace(symbol: "delete.left", font: KeyboardAppearance.functionFont, accessibility: String(localized: "删除"))
        case .nextKeyboard:
            return KeyFace(symbol: "globe", font: KeyboardAppearance.functionFont, accessibility: String(localized: "下一个键盘"))
        case .space:
            // 中文时同系统:空格上不写字,右下角一个小「拼」。
            guard zh else { return text("space") }
            var f = text("")
            f.accessibility = String(localized: "空格")
            f.corner = "拼"
            return f
        case .page(let p):
            switch p {
            case .letters: return text(zh ? "拼音" : "ABC")
            case .numbers: return text("123")
            case .symbols: return text("#+=")
            }
        case .toggleLanguage:
            // 「中/英」:当前这一种用正文色,另一种淡一些。
            let s = NSMutableAttributedString()
            let on: [NSAttributedString.Key: Any] = [.font: KeyboardAppearance.functionFont, .foregroundColor: UIColor.label]
            let off: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel]
            s.append(NSAttributedString(string: "中", attributes: zh ? on : off))
            s.append(NSAttributedString(string: "/", attributes: off))
            s.append(NSAttributedString(string: "英", attributes: zh ? off : on))
            return KeyFace(title: s, font: KeyboardAppearance.functionFont, accessibility: String(localized: "中英文切换"))
        case .returnKey:
            let type = host?.returnKeyType ?? .default
            if [.search, .google, .yahoo].contains(type) {
                // 系统键盘搜索时回车是放大镜。
                return KeyFace(symbol: "magnifyingglass", font: KeyboardAppearance.functionFont, prominent: true,
                               accessibility: Self.returnTitle(type, chinese: zh))
            }
            var f = text(Self.returnTitle(type, chinese: zh))
            f.prominent = ![.default, .continue].contains(type)
            return f
        }
    }

    static func returnTitle(_ type: UIReturnKeyType, chinese zh: Bool) -> String {
        switch type {
        case .go: zh ? "前往" : "go"
        case .google, .yahoo, .search: zh ? "搜索" : "search"
        case .join: zh ? "加入" : "join"
        case .next: zh ? "下一项" : "next"
        case .route: zh ? "路线" : "route"
        case .send: zh ? "发送" : "send"
        case .done: zh ? "完成" : "done"
        case .emergencyCall: zh ? "紧急呼叫" : "call"
        case .continue: zh ? "继续" : "continue"
        default: zh ? "换行" : "return"
        }
    }

    // MARK: - lodo 面板

    private func openAsk() {
        guard let services else { return }
        guard services.hasFullAccess else { return showFullAccessNotice() }
        panelDocument.text = ""
        enterEditing(.ask)
    }

    private func enterEditing(_ state: Panel) {
        if !panelEditing { session.switchDocument(to: panelDocument) }
        setPanel(state)
    }

    private func leaveEditing() {
        if panelEditing, let host { session.switchDocument(to: host.document) }
    }

    private func setPanel(_ state: Panel) {
        let wasVisible = panelVisible
        panel = state
        renderPanel()
        if wasVisible != panelVisible { layout() } else { render() }
    }

    private func closePanel() {
        guard panelVisible else { return }
        askTask?.cancel()
        askTask = nil
        leaveEditing()
        services?.endConversation()
        setPanel(.closed)
    }

    private func showFullAccessNotice() {
        leaveEditing()
        setPanel(.notice)
        panelRow.showMessage(text: String(localized: "要先在系统设置里给 lodo 键盘打开「允许完全访问」(设置 → 通用 → 键盘 → 键盘 → lodo)"))
    }

    private func renderPanel() {
        panelRow.isHidden = !panelVisible
        replyView.isHidden = true
        switch panel {
        case .closed, .notice:
            break
        case .ask:
            let send = LodoPanelRow.iconButton("arrow.up", label: String(localized: "发送")) { [weak self] in self?.submitAsk() }
            send.isEnabled = !panelDocument.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            panelRow.showInput(text: panelDocument.display,
                               placeholder: String(localized: "问 lodo…"), buttons: [send])
        case .thinking(let question):
            panelRow.showMessage(text: question, busy: true)
        case .reply(let question, let reply):
            panelRow.showMessage(text: question)
            showReply(reply)
        }
        keys.isHidden = !grid.isHidden || { if case .reply = panel { true } else { false } }()
        nineColumn.isHidden = !usesNineKey || keys.isHidden
        bar.isHidden = { if case .reply = panel { true } else { false } }()
    }

    private func submitAsk(_ override: String? = nil) {
        guard let services else { return }
        guard services.hasFullAccess else { return showFullAccessNotice() }
        session.commitRaw()
        if let override { panelDocument.text = override }
        let question = panelDocument.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if !panelEditing { session.switchDocument(to: panelDocument) }
        setPanel(.thinking(question))
        askTask?.cancel()
        askTask = Task { [weak self] in
            var reply: LodoReply
            do {
                reply = try await services.ask(question)
            } catch {
                guard !Task.isCancelled else { return }
                reply = LodoReply(text: error.localizedDescription, insertable: false)
                reply.failed = true
            }
            guard !Task.isCancelled, let self else { return }
            self.leaveEditing()
            self.setPanel(.reply(question: question, reply))
        }
    }

    /// 等回答时用户又打字了:取消这次请求,回到改问题(问题原文还在输入框里)。
    private func resumeEditingIfThinking() {
        guard case .thinking = panel else { return }
        askTask?.cancel()
        askTask = nil
        setPanel(.ask)
    }

    private func showReply(_ reply: LodoReply) {
        var actions: [UIButton] = []
        if reply.insertable {
            actions.append(LodoPanelRow.button(String(localized: "插入"), prominent: true) { [weak self] in
                guard let self, let host = self.host else { return }
                self.closePanel()
                host.document.insertText(reply.text)
            })
            actions.append(LodoPanelRow.button(String(localized: "复制")) { [weak self] in
                UIPasteboard.general.string = reply.text
                self?.panelRow.showMessage(text: String(localized: "已复制"))
            })
        }
        if let undo = reply.undo {
            actions.append(LodoPanelRow.button(String(localized: "撤销")) { [weak self] in
                let message = undo() ? String(localized: "已撤销") : String(localized: "已经存进 lodo 了,去 lodo 里删")
                self?.panelRow.showMessage(text: message)
            })
        }
        if reply.failed, case .reply(let question, _) = panel {
            // 出错了:问题原文放回输入框,改一下或直接再发。
            actions.append(LodoPanelRow.button(String(localized: "改一下再问"), prominent: true) { [weak self] in
                self?.panelDocument.text = question
                self?.enterEditing(.ask)
            })
        } else {
            actions.append(LodoPanelRow.button(String(localized: "接着问")) { [weak self] in
                self?.panelDocument.text = ""
                self?.enterEditing(.ask)
            })
        }
        let options = reply.options.map { option in
            LodoPanelRow.button(option) { [weak self] in self?.submitAsk(option) }
        }
        replyView.isHidden = false
        replyView.show(reply, actions: actions, optionButtons: options)
    }

    private func setExpanded(_ on: Bool) {
        bar.isExpanded = on
        grid.isHidden = !on
        keys.isHidden = on || !replyView.isHidden
        if on { grid.show(displayedChoices(), resetScroll: true) }
        placeGlobe()
    }

    private func selectCandidate(_ choice: CandidateChoice) {
        resumeEditingIfThinking() // 等回答时选词也是在改问题
        let wasComposing = session.isComposing
        switch choice {
        case .candidate(let c, let key): session.select(c, decodedFor: key)
        case .raw: session.commitRawLetters()
        case .suggestion(let word): session.selectSuggestion(word)
        }
        if wasComposing && !session.isComposing { didCommit() }
        haptics.play(.candidate)
        setExpanded(false) // 选词时 session 已经刷新过一遍了,这里不用再 render
    }

    /// 上屏学了词:扩展随时可能被系统杀掉,停手 3 秒就存一次(键盘收起时立刻存)。
    private func didCommit() {
        dictionaryVersion += 1
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveUserDictionary() }
        }
    }

    private func saveUserDictionary() {
        saveTimer?.invalidate()
        guard let url = userDictionaryURL, dictionaryVersion > savedVersion else { return }
        let version = dictionaryVersion
        let dict = session.engine.userDictionary
        Task { [weak self, saver] in
            let ok = await saver.save(dict, version: version, to: url)
            if ok, let self { self.savedVersion = max(self.savedVersion, version) }
        }
    }

    @objc private func accessibilityChanged() {
        keyFaceState = nil // 键帽配色/描边跟着辅助功能设置变
        render()
    }

    // MARK: - 截图 / 演示用(LodoKeyboardDemo),扩展里不调

    /// 按一串键:字母照打;`␣` 空格,`⏎` 回车,`⌫` 删除,`#` 切 123,`@` 切 #+=,`~` 中/英,`^` shift,
    /// `1`…`9` 选第几个候选。
    public func simulate(_ script: String) {
        for ch in script {
            switch ch {
            case "␣": keyArea(trigger: .space)
            case "⏎": keyArea(trigger: .returnKey)
            case "⌫": keyArea(trigger: .delete)
            case "#": keyArea(trigger: .page(.numbers))
            case "@": keyArea(trigger: .page(.symbols))
            case "~": keyArea(trigger: .toggleLanguage)
            case "^": keyArea(trigger: .shift)
            case "2"..."9" where usesNineKey: keyArea(trigger: .letter(ch)) // 九宫格里数字就是按键
            case "1"..."9":
                let choices = displayedChoices(), i = Int(String(ch))! - 1
                if choices.indices.contains(i) { selectCandidate(choices[i]) }
            default: keyArea(trigger: .letter(ch))
            }
        }
    }

    public func simulateExpandCandidates() { setExpanded(true) }
    public func simulateOpenAsk() { openAsk() }
    public func simulateSubmitAsk() { submitAsk() }

    /// 摆出按住某个字母时的样子(放大气泡)。
    public func simulateHolding(_ letter: Character) { keys.debugHold(.letter(letter)) }
}

extension KeyboardController: KeyAreaDelegate {
    func keyArea(trigger action: KeyAction) {
        if action == .nextKeyboard { return } // 地球键走上层那颗真按钮
        resumeEditingIfThinking()
        // ✨ 输入框里按回车 = 发送。
        if case .ask = panel, action == .returnKey, !session.isComposing {
            submitAsk()
            return
        }
        let wasComposing = session.isComposing
        session.handle(action)
        if wasComposing && !session.isComposing { didCommit() }
    }

    /// 拼到一半不挪光标(挪走了组合就对不上);面板里的输入框没有光标可挪。
    func keyAreaCanMoveCursor() -> Bool { !session.isComposing && !panelEditing }

    func keyArea(moveCursorBy offset: Int) {
        guard keyAreaCanMoveCursor() else { return }
        host?.moveCursor(by: offset)
    }

    func keyAreaPlayClick(for action: KeyAction) {
        UIDevice.current.playInputClick()
        switch action {
        case .space: haptics.play(.space)
        case .delete: haptics.play(.delete)
        default: haptics.play(.key)
        }
    }

    func keyAreaRepeatFeedback() { haptics.play(.repeatDelete) }
}

extension KeyboardController: CandidateBarDelegate {
    func candidateBar(select choice: CandidateChoice) { selectCandidate(choice) }
    func candidateBarToggleExpanded() { setExpanded(grid.isHidden) }
    func candidateBarAsk() { openAsk() }
}
#endif
