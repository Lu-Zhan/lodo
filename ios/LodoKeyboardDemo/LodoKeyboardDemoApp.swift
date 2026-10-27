import LodoKeyboardModel
import LodoKeyboardUI
import SwiftUI
import UIKit

/// 只用来截图核对键盘的小 app:模拟器里启用不了第三方键盘,就把键盘视图直接摆在页面底部,
/// 宿主是假的(字写进上面那个文本框)。不进主 app,免得主 app 再背一份词库和模型。
///
/// 启动参数:
///   --type <脚本>      按一串键(规则见 KeyboardController.simulate)
///   --expand           展开全部候选
///   --hold <字母>      摆出按住某个字母时的放大气泡
///   --return <类型>    宿主的回车键类型:search / send / done / go
///   --dark / --light   深浅色
///   --ask              打开 ✨ 面板;配 --type 写问题,再加 --send 出假回答
///   --nine             中文用九宫格(--type 里 2–9 就是按键)
///   --no-full-access   模拟没开「完全访问」
///   --accent blue      换成主 app 的「靛蓝」档(核对强调色跟随)
@main
struct LodoKeyboardDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoKeyboardScreen().ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

struct DemoKeyboardScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DemoKeyboardViewController { DemoKeyboardViewController() }
    func updateUIViewController(_ vc: DemoKeyboardViewController, context: Context) {}
}

final class DemoDocument: TextDocument {
    var text = "" { didSet { onChange?(display) } }
    /// 标记文字(正在拼的拼音),显示时带下划线,同真实输入框。
    var marked = "" { didSet { onChange?(display) } }
    var onChange: ((NSAttributedString) -> Void)?
    var contextBeforeInput: String? { text + marked }
    func insertText(_ t: String) { text += marked + t; marked = "" }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    var supportsMarkedText: Bool { true }
    func setMarkedText(_ t: String) { marked = t }
    func unmarkText() { let m = marked; marked = ""; text += m }
    var display: NSAttributedString {
        let s = NSMutableAttributedString(string: text)
        s.append(NSAttributedString(string: marked, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]))
        return s
    }
}

/// 假的 lodo 服务:不写 App Group、不联网,回答是写死的。
final class DemoServices: LodoServices {
    var hasFullAccess = true
    func ask(_ question: String) async throws -> LodoReply {
        try await Task.sleep(for: .milliseconds(300))
        return LodoReply(text: "家里的 Wi-Fi 叫 lodo-home,密码是 sunflower2026。", insertable: true,
                         note: "来自记忆「家里 Wi-Fi」")
    }
    func endConversation() {}
}

final class DemoKeyboardViewController: UIViewController, KeyboardHost {
    private let services = DemoServices()
    private let doc = DemoDocument()
    var document: TextDocument { doc }
    var needsInputModeSwitchKey: Bool { false }
    var returnKeyType: UIReturnKeyType = .default
    var keyboardType: UIKeyboardType { .default }
    var autocapitalizationType: UITextAutocapitalizationType { .sentences }
    private var keyboard: KeyboardController!
    private let field = UILabel()
    private var scripted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        returnKeyType = switch value("--return") {
        case "search": .search
        case "send": .send
        case "done": .done
        case "go": .go
        default: .default
        }
        view.backgroundColor = .systemBackground
        field.numberOfLines = 0
        field.font = .systemFont(ofSize: 20)
        field.text = "lodo 键盘"
        field.textColor = .secondaryLabel
        doc.onChange = { [weak self] in self?.field.attributedText = $0; self?.field.textColor = .label }
        keyboard = try! KeyboardController(host: self, userDictionaryURL: nil)
        services.hasFullAccess = !args.contains("--no-full-access")
        keyboard.services = services
        keyboard.nineKey = args.contains("--nine") // 中文九宫格
        if let scale = value("--key-height").flatMap(Double.init) { keyboard.keyHeightScale = CGFloat(scale) } // 按键高度倍数
        if value("--accent") == "blue" {
            keyboard.accent = KeyboardAccent(accent: KeyboardAccent.dynamic(light: 0x0A58CA, dark: 0x7FB3FF),
                                             fill: KeyboardAccent.dynamic(light: 0x0A58CA, dark: 0x4DA3FF),
                                             onFill: KeyboardAccent.dynamic(light: 0xFFFFFF, dark: 0x05183A))
        }
        let kb = keyboard.rootView
        kb.translatesAutoresizingMaskIntoConstraints = false // demo 里自己用约束摆;扩展里归系统管
        view.addSubview(field)
        view.addSubview(kb)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 系统键盘底下还有一截放地球键和听写键的区域,这里用安全区代替。
            kb.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        // 普通 app 里 UIInputView(.keyboard) 不画背板(背板是系统键盘宿主画的),
        // 这里垫一块接近系统键盘底色的灰,只为截图看得出键帽。
        let backdrop = UIView()
        backdrop.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.82, green: 0.835, blue: 0.86, alpha: 1) }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, belowSubview: kb)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: kb.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        keyboard.willAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 设在 window 上:SwiftUI 宿主会盖掉子控制器上的 overrideUserInterfaceStyle。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--dark") { view.window?.overrideUserInterfaceStyle = .dark }
        if args.contains("--light") { view.window?.overrideUserInterfaceStyle = .light }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyboard.layout()
        guard !scripted, keyboard.rootView.bounds.width > 0 else { return }
        scripted = true
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        // 等模型在后台载入完再按,截出来的候选才是重排过的。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if args.contains("--ask") { keyboard.simulateOpenAsk() }
            if let script = value("--type") { keyboard.simulate(script) }
            if args.contains("--send") { keyboard.simulateSubmitAsk() }
            if args.contains("--expand") { keyboard.simulateExpandCandidates() }
            if let hold = value("--hold")?.first { keyboard.simulateHolding(hold) }
        }
    }

    func moveCursor(by offset: Int) {}
    func dismissKeyboard() {}
    func attachInputModeSwitch(to button: UIButton) {}
}
