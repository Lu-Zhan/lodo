import UIKit
import Combine
import SwiftUI
import LodoCore

/// 系统键盘的按键音要求 inputView 遵守 UIInputViewAudioFeedback,
/// 并且只在用户打开了「键盘按键音」时才响。
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRoot>?
    private let state = KeyboardState()
    private var heightConstraint: NSLayoutConstraint?

    private var aiObservation: AnyCancellable?
    /// 布局用的 AI 开关。sink 在 willSet 里触发,那一刻 state.aiOpen 还是旧值,
    /// 动画里的 layoutIfNeeded 又会回调 viewWillLayoutSubviews——读 state 会把高度改回去。
    private var aiOpenForLayout = false

    override func loadView() {
        view = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.proxy = textDocumentProxy
        state.inputModeTarget = self
        syncEnvironment()
        let host = UIHostingController(rootView: KeyboardRoot(state: state))
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // 背景留空:系统键盘底板(iOS 26 起是 Liquid Glass)由系统画在扩展后面,
        // 自己再铺一层反而和原生键盘对不上。
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        let height = view.heightAnchor.constraint(equalToConstant: currentHeight)
        // 系统在布局初期会先塞一个自己的高度约束,999 让出这一瞬,之后以我们为准。
        height.priority = UILayoutPriority(999)
        heightConstraint = height
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
        // 点 AI 键时键盘整体长高一行(对话框),退出时缩回。@Published 在 willSet
        // 时发值,所以用发出来的新值算,不读 state.aiOpen。
        aiObservation = state.$aiOpen.removeDuplicates().dropFirst().sink { [weak self] open in
            self?.updateHeight(aiOpen: open, animated: true)
        }
    }

    private func updateHeight(aiOpen: Bool, animated: Bool) {
        aiOpenForLayout = aiOpen
        let target = KeyboardLayout.height(landscape: isLandscape, aiOpen: aiOpen)
        guard heightConstraint?.constant != target else { return }
        heightConstraint?.constant = target
        guard animated, !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.superview?.layoutIfNeeded()
            self.view.layoutIfNeeded()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncEnvironment()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight(aiOpen: aiOpenForLayout, animated: false)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        state.proxy = textDocumentProxy
        syncEnvironment()
    }

    private var isLandscape: Bool { traitCollection.verticalSizeClass == .compact }

    private var currentHeight: CGFloat {
        KeyboardLayout.height(landscape: isLandscape, aiOpen: aiOpenForLayout)
    }

    private func syncEnvironment() {
        state.hasFullAccess = hasFullAccess
        state.needsGlobe = needsInputModeSwitchKey
        state.returnKeyType = textDocumentProxy.returnKeyType ?? .default
    }
}

/// 结果卡上的主操作。
enum KeyboardCardAction: Equatable {
    /// AI 的回答已经写进剪贴板,可以再一键插入到光标处。
    case insert(String)
    /// 已暂存进收件箱,主 app 唤醒前删掉文件即可撤销。
    case undo(URL)
    case confirmCreates([ParsedTask])
    case saveSuggestion(String)
}

struct KeyboardCard: Equatable {
    var text: String
    var note = ""
    var action: KeyboardCardAction?
}

@MainActor
final class KeyboardState: ObservableObject {
    @Published var ime: PinyinIME
    @Published var page = 0
    @Published var shift = false
    @Published var locked = false

    // ---- AI ----
    @Published var aiOpen = false
    @Published var aiText = ""
    @Published var busy = false
    /// 结果卡,盖在按键区上面。
    @Published var card: KeyboardCard?
    /// AI 的反问;选项层盖在按键区上面。选项层收起后问题仍保留,可以回去接着选。
    @Published var questions: [AskQuestion] = []
    @Published var questionIndex = 0
    @Published var picked: Set<String> = []
    @Published var showingOptions = false
    /// 在选项层点了最后那行「其他」,正在输入框里写选项之外的回答。
    @Published var answeringOther = false
    /// 用户选完选项、键盘已经回到普通输入,AI 仍在后台处理。
    @Published var backgroundStatus: String?
    /// 顶栏上停留一秒的提示(「OK，已完成」「等下再决定」)。
    @Published var toast: String?

    @Published var hasFullAccess = false
    @Published var needsGlobe = true
    @Published var returnKeyType: UIReturnKeyType = .default

    var proxy: UITextDocumentProxy?
    weak var inputModeTarget: UIInputViewController?
    private var askPrompt = ""
    private var askAnswers: [String] = []
    private var lastShiftTap = Date.distantPast
    private var requestTask: Task<Void, Never>?
    /// 被取消的旧请求收尾时不能把新请求的 busy/状态冲掉。
    private var requestID = 0
    private var toastTask: Task<Void, Never>?
    private var snapshot = KeyboardExchange.Snapshot(memories: [], tasks: [])

    init() {
        let dictionary = Bundle.main.url(forResource: "PinyinDictionary", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let learned = KeyboardExchange.settings?.dictionary(forKey: "keyboard.learned") as? [String: String] ?? [:]
        ime = PinyinIME.load(dictionary, learned: learned)
        if let url = KeyboardExchange.snapshotURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(KeyboardExchange.Snapshot.self, from: data) {
            snapshot = decoded
        }
        // LodoCore 的 AppSettings / AgentSkillStore 读 standard defaults。扩展的
        // standard defaults 与主 app 隔离,启动时从 App Group 镜像恢复到本进程。
        if let shared = KeyboardExchange.settings {
            for key in [AppSettings.aiProviderKey, AppSettings.aiModelKey,
                        AppSettings.aiCustomEndpointKey, AppSettings.useBuiltInKeyKey,
                        AppSettings.agentPersonaStyleKey,
                        AppSettings.agentPersonaCustomKey, AppSettings.languageKey] {
                if let value = shared.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
            }
            for skill in AgentSkillID.allCases {
                let key = "agentSkillEnabled.\(skill.rawValue)"
                if let value = shared.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
            }
        }
        // 键盘里默认不思考:打字间隙等不起推理模型那十几秒,不跟随主 app 的思考强度。
        UserDefaults.standard.set("off", forKey: AppSettings.thinkingLevelKey)
    }

    var composing: Bool { !ime.raw.isEmpty || !ime.committed.isEmpty }
    var hasPendingQuestion: Bool { !questions.isEmpty }
    var currentQuestion: AskQuestion? {
        questions.indices.contains(questionIndex) ? questions[questionIndex] : nil
    }

    // MARK: - 输入

    /// 普通模式写进宿主 app,AI 模式写进 AI 输入框。
    private func output(_ text: String) {
        if aiOpen { aiText += text } else { proxy?.insertText(text) }
    }

    func type(_ key: String) {
        if page != 0 || shift {
            flushComposition()
            output(shift ? key.uppercased() : key)
            if !locked { shift = false }
        } else { ime.type(key) }
    }

    func delete() {
        if composing { ime.delete(); return }
        if aiOpen { if !aiText.isEmpty { aiText.removeLast() } }
        else { proxy?.deleteBackward() }
    }

    func select(_ word: String) {
        if let result = ime.select(word) { output(result) }
        KeyboardExchange.settings?.set(ime.learnedWords(), forKey: "keyboard.learned")
    }

    func flushComposition() {
        guard composing else { return }
        output(ime.committed + (ime.raw.isEmpty ? "" : (ime.candidates.first ?? ime.raw)))
        ime.clear()
    }

    func space() {
        if !ime.raw.isEmpty { select(ime.candidates.first ?? ime.raw) }
        else { output(" ") }
    }

    /// 和系统拼音键盘一样:拼音还没选字时回车直接上屏字母。
    func enter() {
        if composing {
            output(ime.committed + ime.raw)
            ime.clear()
            return
        }
        if aiOpen { submitInput() } else { proxy?.insertText("\n") }
    }

    func shiftTap() {
        if Date().timeIntervalSince(lastShiftTap) < 0.35 { locked = true; shift = true }
        else if locked { locked = false; shift = false }
        else { shift.toggle() }
        lastShiftTap = .now
    }

    func punctuation(_ mark: String) {
        flushComposition()
        output(mark)
    }

    // MARK: - AI 模式

    /// 右上角那颗键:普通模式下打开 AI,AI 模式下就是 ✕。
    func toggleAI() {
        if aiOpen { closeAI(toast: hasPendingQuestion && card == nil ? "等下再决定" : nil) }
        else { openAI() }
    }

    func openAI() {
        flushComposition()
        aiOpen = true
        answeringOther = false
        if hasPendingQuestion { showingOptions = true }
    }

    func closeAI(toast message: String? = nil) {
        ime.clear()
        if busy { requestTask?.cancel(); busy = false }
        aiOpen = false
        showingOptions = false
        answeringOther = false
        card = nil
        aiText = ""
        if let message { showToast(message) }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    /// 回车/发送键:写「其他」时是回答当前问题,否则是一句新的话。
    func submitInput() {
        flushComposition()
        let text = aiText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        aiText = ""
        if answeringOther {
            answeringOther = false
            answer([text])
        } else {
            questions = []
            send(text, afterDecision: false)
        }
    }

    func showOptions() {
        flushComposition()
        answeringOther = false
        showingOptions = true
    }

    func writeOther() {
        showingOptions = false
        answeringOther = true
    }

    func pick(_ option: AskOption) {
        guard let question = currentQuestion else { return }
        if question.multiSelect {
            if picked.contains(option.label) { picked.remove(option.label) }
            else { picked.insert(option.label) }
        } else {
            answer([option.label])
        }
    }

    func confirmPicked() {
        guard let question = currentQuestion else { return }
        answer(question.options.map(\.label).filter { picked.contains($0) })
    }

    /// 答完当前题;最后一题答完就回到普通输入,让 AI 在后台带着补充信息重来一次。
    private func answer(_ labels: [String]) {
        guard let question = currentQuestion, !labels.isEmpty else { return }
        askAnswers.append("\(question.question) → \(labels.joined(separator: "、"))")
        picked = []
        if questionIndex + 1 < questions.count {
            questionIndex += 1
            showingOptions = true
            return
        }
        let prompt = askPrompt + "\n补充信息:\n" + askAnswers.joined(separator: "\n")
        questions = []
        closeAI()
        send(prompt, afterDecision: true)
    }

    /// afterDecision:用户刚在选项层做完决定,键盘已回到普通输入。能直接办完的
    /// (暂存了待办/记忆)就只在顶栏闪一句「OK，已完成」,需要再看一眼的才重新弹卡片。
    private func send(_ prompt: String, afterDecision: Bool) {
        guard hasFullAccess else {
            aiOpen = true
            card = KeyboardCard(text: "使用 AI 需要允许完全访问",
                                note: "设置 → 通用 → 键盘 → 键盘 → lodo → 允许完全访问")
            return
        }
        card = nil
        if afterDecision { backgroundStatus = "正在处理…" } else { busy = true }
        if !afterDecision { askPrompt = prompt; askAnswers = [] }
        requestID += 1
        let id = requestID
        requestTask = Task {
            defer { if id == requestID { busy = false; backgroundStatus = nil } }
            do {
                let outcome = try await run(prompt)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .ask(let ask):
                    questions = ask
                    questionIndex = 0
                    picked = []
                    aiOpen = true
                    answeringOther = false
                    showingOptions = true
                case .card(let result, let autoApplied):
                    if afterDecision && autoApplied {
                        showToast("OK，已完成")
                    } else {
                        aiOpen = true
                        card = result
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                aiOpen = true
                card = KeyboardCard(text: error.localizedDescription)
            }
        }
    }

    private enum Outcome {
        case ask([AskQuestion])
        case card(KeyboardCard, autoApplied: Bool)
    }

    private func run(_ prompt: String) async throws -> Outcome {
        var history: [(role: String, content: String)] = []
        var current = prompt
        for _ in 0..<3 {
            let outcome = try await DeepSeekClient.command(
                current, tasks: snapshot.tasks.map { ($0.uuid, $0.task) },
                memoryEnabled: true, history: history)
            switch outcome {
            case .toolCall(let thought, .searchMemory(let query)):
                let found = searchMemories(query).map { "- \($0.title): \($0.summary)\n\($0.excerpt)" }
                    .joined(separator: "\n")
                history.append((role: "assistant", content: "思考:\(thought);查记忆:\(query)"))
                history.append((role: "user", content: "检索结果:\n\(found)"))
                current = "请基于检索结果回答最初的问题:\(prompt)"
            case .toolCall:
                return .card(KeyboardCard(text: "此操作请在 lodo 的 AI 助手里完成。"), autoApplied: false)
            case .ask(let ask):
                return .ask(ask)
            case .actions(let actions):
                return await handle(actions)
            }
        }
        return .card(KeyboardCard(text: "检索了几轮仍未得到结果,请在 lodo 里继续。"), autoApplied: false)
    }

    private func searchMemories(_ query: String) -> [KeyboardExchange.Memory] {
        MemorySearch.rank(question: query, items: snapshot.memories.enumerated().map { index, item in
            (index: index, text: "\(item.title) \(item.summary) \(item.tags.joined(separator: " ")) \(item.excerpt)",
             createdAt: item.createdAt)
        }).map { snapshot.memories[$0] }
    }

    private func handle(_ actions: [AIAction]) async -> Outcome {
        let creates = actions.compactMap { action -> ParsedTask? in
            if case .create(let task) = action { return task }; return nil
        }
        if creates.count > 1 {
            return .card(KeyboardCard(
                text: "准备添加 \(creates.count) 条任务:\n" + creates.map { "• \($0.title)" }.joined(separator: "\n"),
                action: .confirmCreates(creates)), autoApplied: false)
        }
        var messages: [String] = []
        var action: KeyboardCardAction?
        var note = ""
        // 只有全部都是"已经替用户办完"的操作,才算可以只闪一句提示就收起。
        var autoApplied = !actions.isEmpty
        for item in actions {
            switch item {
            case .answer(let text):
                UIPasteboard.general.string = text
                messages.append(text)
                action = .insert(text); note = "已复制到剪贴板"
                autoApplied = false
            case .askMemory(let question):
                let items = searchMemories(question).enumerated().map { index, item in
                    (uuid: String(index), title: item.title, summary: item.summary,
                     tags: item.tags, excerpt: item.excerpt)
                }
                do {
                    let (answer, _) = try await DeepSeekClient.askMemory(question: question, items: items)
                    UIPasteboard.general.string = answer
                    messages.append(answer)
                    action = .insert(answer); note = "已复制到剪贴板"
                } catch { messages.append(error.localizedDescription) }
                autoApplied = false
            case .create(let task):
                do {
                    let url = try KeyboardExchange.queueTask(task)
                    messages.append("已加入任务「\(task.title)」")
                    action = action ?? .undo(url); note = "打开 lodo 后生效"
                } catch { messages.append(error.localizedDescription); autoApplied = false }
            case .memorize(let text):
                do {
                    let url = try KeyboardExchange.queueMemory(text: text)
                    messages.append("已收藏到记忆")
                    action = action ?? .undo(url); note = "打开 lodo 后生效"
                } catch { messages.append(error.localizedDescription); autoApplied = false }
            case .autoMemorize(let title, let text):
                do {
                    let url = try KeyboardExchange.queueMemory(text: text, title: title, automatic: true)
                    messages.append("已记下「\(title)」")
                    action = action ?? .undo(url); note = "打开 lodo 后生效"
                } catch { messages.append(error.localizedDescription); autoApplied = false }
            case .suggestMemorize(let text):
                messages.append(text)
                action = .saveSuggestion(text)
                autoApplied = false
            default:
                messages.append("修改、完成、删除和规划行程请在 lodo 里操作。")
                autoApplied = false
            }
        }
        if messages.isEmpty { messages.append("没有需要处理的内容。") }
        return .card(KeyboardCard(text: messages.joined(separator: "\n"), note: note, action: action),
                     autoApplied: autoApplied)
    }

    func perform(_ action: KeyboardCardAction) {
        switch action {
        case .insert(let text):
            closeAI()
            proxy?.insertText(text)
            showToast("已插入")
        case .undo(let url):
            try? FileManager.default.removeItem(at: url)
            closeAI(toast: "已撤销")
        case .confirmCreates(let tasks):
            for task in tasks { _ = try? KeyboardExchange.queueTask(task) }
            closeAI(toast: "OK，已完成")
        case .saveSuggestion(let text):
            _ = try? KeyboardExchange.queueMemory(text: text)
            closeAI(toast: "已收藏")
        }
    }
}
