import SwiftUI
import SwiftData
import WatchKit
import LodoCore

/// Watch 语音助手:一打开(表盘快捷按钮 / 首页右下角麦克风)就开始听,说完自动停 →
/// 屏幕上是思考中的轮换词 → 出结果。右下角麦克风再点一下接着说,带着这一轮的上下文
/// (多轮对话只在这次打开期间有效,不写进手机 AI 页那条持续对话)。
///
/// 能做的事:
/// - 任务的新增/修改/完成/删除(可批量)——**仍然先列「即将执行」清单,一键确认才落库**
///   (用户早先明确要求的安全阀,手表上没有撤销);
/// - 记一下(`memorize`,直接落库)、顺带记录(`auto_memorize`,静默)、偏好(静默);
/// - 查记忆(`ask_memory` / ReAct `search_memory`)、普通问答(`answer`)。
/// 删除记忆、行程、资产这些要看详情才放心的操作不在手表上做,如实请用户去 iPhone。
struct WatchAgentView: View {
    /// 打开即开始听(表盘快捷按钮、首页麦克风都是 true)。
    var autoListen = true

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    private var pending: [TaskItem]

    @State private var speech = WatchSpeechInput()
    @State private var entries: [WatchAgentEntry] = []
    /// 回传给模型的多轮上下文(用户原话 + 回复的文字版),最多留 16 条,同手机。
    @State private var history: [(role: String, content: String)] = []
    /// 非 nil = 正在思考(含转写),记着这一轮的起点和轮换词种子。
    @State private var thinking: (start: Date, seed: Int)?
    @State private var requestTask: Task<Void, Never>?

    @State private var pendingActions: [AIAction] = []
    /// 当前等着确认的那张清单;执行或作废之后变成只读记录。
    @State private var activeConfirmID: UUID?
    @State private var executedConfirmIDs: Set<UUID> = []
    /// AI 反问的第一道题(手表只展示一道);下一句话或点选项都当作对它的补充。
    @State private var activeClarifyID: UUID?
    @State private var clarifyBase = ""
    @State private var savedSuggestionIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if speech.state == .recording {
                    listening
                } else {
                    conversation
                }
            }
            .navigationTitle("Lodo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { bottomControls }
        }
        .task {
            if autoListen && entries.isEmpty { await startListening() }
        }
        // 一停下录音(自动或手动)就进入思考:转写也是等待的一部分,用户看到的是同一串轮换词。
        .onChange(of: speech.state) { _, state in
            switch state {
            case .transcribing:
                WKInterfaceDevice.current().play(.stop)
                if thinking == nil { thinking = (Date(), Int.random(in: 0..<Int.max)) }
            case .idle, .recording:
                break
            }
        }
        .onDisappear {
            speech.cancel()
            requestTask?.cancel()
        }
    }

    // MARK: - 界面

    private var listening: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            WatchRecordingWaveform(level: speech.audioLevel)
            Text("正在听…")
                .font(.headline)
            Text("说完会自动结束")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty && !isBusy {
                        emptyHint
                    }
                    ForEach(entries) { entry in
                        entryView(entry).id(entry.id)
                    }
                    if let thinking {
                        WatchThinkingText(seed: thinking.seed, start: thinking.start)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .id(Self.thinkingAnchor)
                    }
                }
                .padding(.horizontal, 2)
                // 给右下角的麦克风让出位置,最后一行不被它压住。
                .padding(.bottom, 8)
            }
            // 录完音这一页是重新建出来的:一出现就停在最底下(思考词/最新一条)。
            .defaultScrollAnchor(.bottom)
            .onChange(of: entries.count) {
                guard let last = entries.last else { return }
                withAnimation {
                    if last.isReply {
                        // 回复从头读。
                        proxy.scrollTo(last.id, anchor: .top)
                    } else if thinking != nil {
                        proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
                    } else {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: thinking != nil) { _, isThinking in
                guard isThinking else { return }
                withAnimation { proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom) }
            }
        }
    }

    private static let thinkingAnchor = "thinking"

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("轻点右下角说话")
                .font(.headline)
            Group {
                Text("“明早 8 点提醒我交报告”")
                Text("“记一下,车停在 B2 区 36 号”")
                Text("“我的车停在哪了？”")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func entryView(_ entry: WatchAgentEntry) -> some View {
        switch entry.kind {
        case .user(let text):
            Text(text)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply(let text, let symbol):
            Label {
                Text(text).font(.body)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
            }
            .labelStyle(WatchReplyLabelStyle())
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        case .confirm(let lines):
            confirmCard(entry.id, lines: lines)
        case .clarify(let question):
            clarifyCard(entry.id, question: question)
        case .suggest(let text):
            suggestCard(entry.id, text: text)
        }
    }

    private func confirmCard(_ id: UUID, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: icon(for: line)).font(.footnote)
            }
            if activeConfirmID == id {
                Button {
                    performPendingActions()
                } label: {
                    Label("确认执行", systemImage: "checkmark")
                }
                .tint(.green)
                Button("取消", role: .cancel) {
                    pendingActions = []
                    activeConfirmID = nil
                    appendReply("已取消这次操作。", symbol: "xmark.circle")
                }
            } else if executedConfirmIDs.contains(id) {
                Label("已执行", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
        .padding(8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func clarifyCard(_ id: UUID, question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(question.question, systemImage: "questionmark.circle").font(.footnote)
            if activeClarifyID == id {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    Button(option.recommended ? "\(option.label)(推荐)" : option.label) {
                        send(option.label, showsBubble: true)
                    }
                    .font(.footnote)
                }
                Text("也可以直接说出来")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func suggestCard(_ id: UUID, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.footnote)
            if savedSuggestionIDs.contains(id) {
                Label("已收藏", systemImage: "bookmark.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    savedSuggestionIDs.insert(id)
                    Task { _ = await WatchMemory.save(text, context: context) }
                } label: {
                    Label("收藏这条", systemImage: "bookmark")
                }
            }
        }
        .padding(8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func icon(for line: String) -> String {
        if line.hasPrefix("新建") { return "plus.circle" }
        if line.hasPrefix("修改") { return "pencil.circle" }
        if line.hasPrefix("完成") { return "checkmark.circle" }
        if line.hasPrefix("删除") { return "trash.circle" }
        return "circle"
    }

    // MARK: - 底部控件:左下键盘(兜底),右下麦克风

    @ToolbarContentBuilder
    private var bottomControls: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if speech.state == .idle && !isBusy {
                // 没配语音识别 / 麦克风被拒 / 不方便出声时的退路:系统输入(含随手写、听写)。
                TextFieldLink(prompt: Text("说点什么…")) {
                    Image(systemName: "keyboard")
                } onSubmit: { text in
                    send(text, showsBubble: true)
                }
                .accessibilityLabel("键盘输入")
            }
            Spacer()
            micButton
        }
    }

    @ViewBuilder
    private var micButton: some View {
        switch speech.state {
        case .recording:
            Button {
                speech.stop(onFinish: handleTranscript)
            } label: {
                Image(systemName: "stop.fill")
            }
            .tint(.red)
            .accessibilityLabel("说完了")
        case .transcribing:
            Button {
                speech.cancel()
                thinking = nil
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("取消")
        case .idle:
            if isBusy {
                Button {
                    requestTask?.cancel()
                    requestTask = nil
                    thinking = nil
                    appendReply("已取消这次操作。", symbol: "xmark.circle")
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("取消")
            } else {
                Button {
                    Task { await startListening() }
                } label: {
                    Image(systemName: "mic.fill")
                }
                .tint(Color.accentColor)
                .accessibilityLabel(entries.isEmpty ? "说话" : "继续说")
            }
        }
    }

    private var isBusy: Bool { thinking != nil || speech.state != .idle }

    // MARK: - 语音

    private func startListening() async {
        if let error = await speech.start(onFinish: handleTranscript) {
            entries.append(WatchAgentEntry(kind: .error(error)))
            WKInterfaceDevice.current().play(.failure)
        } else {
            WKInterfaceDevice.current().play(.start)
        }
    }

    private func handleTranscript(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // 一直没开口(或转写为空):安静收起,不发请求。
                thinking = nil
                return
            }
            send(trimmed, showsBubble: true)
        case .failure(let error):
            thinking = nil
            entries.append(WatchAgentEntry(kind: .error(error.localizedDescription)))
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: - 请求

    private func send(_ text: String, showsBubble: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, requestTask == nil else { return }
        if showsBubble { entries.append(WatchAgentEntry(kind: .user(trimmed))) }
        // 正在等确认的清单被新的一句话顶掉:作废,不再能点。
        activeConfirmID = nil
        pendingActions = []
        var request = trimmed
        if activeClarifyID != nil {
            request = "\(clarifyBase)\n补充:\(trimmed)"
            activeClarifyID = nil
        }
        // 转写那段已经在轮换了就接着轮,不从头再来一遍。
        if thinking == nil { thinking = (Date(), Int.random(in: 0..<Int.max)) }
        let turnHistory = history
        requestTask = Task {
            defer {
                thinking = nil
                requestTask = nil
            }
            do {
                let summary = try await route(request, history: turnHistory)
                guard !Task.isCancelled else { return }
                history.append((role: "user", content: trimmed))
                history.append((role: "assistant", content: summary))
                if history.count > 16 { history.removeFirst(history.count - 16) }
                WKInterfaceDevice.current().play(.success)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                entries.append(WatchAgentEntry(kind: .error(error.localizedDescription)))
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    /// 一轮请求(含最多 3 次 ReAct 查记忆),结果直接追加到 `entries`;
    /// 返回这一轮回复的文字版,存进多轮上下文。
    private func route(_ text: String, history: [(role: String, content: String)]) async throws -> String {
        let taskContext = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        var reasoningHistory = history
        var currentText = text
        for _ in 0..<3 {
            let result = try await DeepSeekClient.command(
                currentText, tasks: taskContext, memoryEnabled: true, history: reasoningHistory)
            try Task.checkCancellation()
            switch result {
            case .ask(let questions):
                guard let question = questions.first else { return "" }
                clarifyBase = text
                let entry = WatchAgentEntry(kind: .clarify(question))
                activeClarifyID = entry.id
                entries.append(entry)
                return question.question
            case .toolCall(let thought, .searchMemory(let query)):
                let observation = WatchMemory.observation(for: query, context: context)
                reasoningHistory.append((role: "assistant", content: "思考:\(thought);查记忆:\(query)"))
                reasoningHistory.append((role: "user", content: "记忆检索结果:\n\(observation)"))
                currentText = "(请基于以上记忆检索结果继续处理最初的请求:\(text))"
            case .toolCall:
                return appendReply("这个要在 iPhone 上问我,手表上还做不了。", symbol: "iphone")
            case .actions(let actions):
                return try await handle(actions)
            }
        }
        throw DeepSeekError.parse("多轮推理超过上限,换个说法试试")
    }

    private func handle(_ actions: [AIAction]) async throws -> String {
        var actions = actions
        // 偏好和顺带记录:同手机,先摘出来静默落盘,不进确认清单。
        var quietlySaved = false
        for action in actions {
            switch action {
            case .rememberPreference(let text):
                AgentPreferences.append(text)
                quietlySaved = true
            case .autoMemorize(let title, let text):
                WatchMemory.saveAuto(title: title, text: text, context: context)
                quietlySaved = true
            default:
                break
            }
        }
        actions.removeAll {
            switch $0 {
            case .rememberPreference, .autoMemorize: return true
            default: return false
            }
        }
        guard !actions.isEmpty else {
            return appendReply(quietlySaved ? "好的,记下了。" : "好的。", symbol: "sparkles")
        }

        if actions.count == 1 {
            switch actions[0] {
            case .answer(let text):
                return appendReply(text, symbol: "sparkles")
            case .memorize(let text):
                guard let title = await WatchMemory.save(text, context: context) else {
                    return appendReply("收藏失败,内容为空。", symbol: "exclamationmark.circle")
                }
                return appendReply("已记下:\(title)", symbol: "bookmark.fill")
            case .askMemory(let question):
                return appendReply(try await WatchMemory.answer(question, context: context),
                                   symbol: "sparkles")
            case .suggestMemorize(let text):
                entries.append(WatchAgentEntry(kind: .suggest(text)))
                return text
            case .deleteMemory:
                return appendReply("删除记忆请在 iPhone 上操作,那边能看清删的是哪一条。", symbol: "iphone")
            default:
                break
            }
        }

        // 剩下的是任务写操作(批量也走这里):列清单,一键确认才执行。
        let taskActions = actions.filter {
            switch $0 {
            case .create, .update, .complete, .delete: return true
            default: return false
            }
        }
        guard !taskActions.isEmpty else {
            return appendReply("这个要在 iPhone 上处理,手表上还做不了。", symbol: "iphone")
        }
        let lines = taskActions.map(describe)
        let entry = WatchAgentEntry(kind: .confirm(lines))
        pendingActions = taskActions
        activeConfirmID = entry.id
        entries.append(entry)
        return "即将执行:\n" + lines.joined(separator: "\n")
    }

    @discardableResult
    private func appendReply(_ text: String, symbol: String) -> String {
        entries.append(WatchAgentEntry(kind: .reply(text, symbol: symbol)))
        return text
    }

    private func describe(_ action: AIAction) -> String {
        switch action {
        case .create(let parsed):
            return "新建:\(parsed.title)(\(TaskItem.format(parsed.remindAt)))"
        case .update(_, let parsed):
            return "修改:\(parsed.title)(\(TaskItem.format(parsed.remindAt)))"
        case .complete(let uuid):
            return "完成:\(title(of: uuid) ?? "未知事项")"
        case .delete(let uuid):
            return "删除:\(title(of: uuid) ?? "未知事项")"
        default:
            return ""
        }
    }

    private func title(of uuid: String) -> String? {
        pending.first { $0.uuid.uuidString == uuid }?.title
    }

    /// 等待确认期间,目标事项可能已被通知按钮改动或完成/删除;
    /// 找不到时静默跳过该条(Watch 屏幕小,不额外展示警示文案)。
    private func performPendingActions() {
        for action in pendingActions {
            switch action {
            case .create(let parsed):
                let task = TaskItem(
                    title: parsed.title, remindAt: parsed.remindAt, allDay: parsed.allDay,
                    repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
                    repeatTimes: parsed.repeatTimes)
                context.insert(task)
                WatchNotificationManager.shared.rebuild(for: task)
            case .update(let uuid, let parsed):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                task.title = parsed.title
                task.remindAt = parsed.remindAt
                task.allDay = parsed.allDay
                task.repeatTypeRaw = parsed.repeatType.rawValue
                task.repeatDays = parsed.repeatDays
                task.repeatTimes = parsed.repeatTimes
                task.phaseRaw = TaskPhase.start.rawValue
                task.nextRemindAt = parsed.remindAt
                WatchNotificationManager.shared.rebuild(for: task)
            case .complete(let uuid):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                WatchNotificationManager.shared.complete(task, context: context)
            case .delete(let uuid):
                guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else { continue }
                WatchNotificationManager.shared.cancelChain(for: task.uuid)
                context.delete(task)
            default:
                continue
            }
        }
        try? context.save()
        if let id = activeConfirmID { executedConfirmIDs.insert(id) }
        pendingActions = []
        activeConfirmID = nil
        WKInterfaceDevice.current().play(.success)
    }
}

/// 对话里的一条。
struct WatchAgentEntry: Identifiable {
    enum Kind {
        case user(String)
        case reply(String, symbol: String)
        case error(String)
        case confirm([String])
        case clarify(AskQuestion)
        case suggest(String)
    }

    let id = UUID()
    let kind: Kind

    /// 回复类的条目滚到它的顶上(从头读),其余滚到底。
    var isReply: Bool {
        switch kind {
        case .user: return false
        default: return true
        }
    }
}

/// 回复:图标顶格对齐第一行,正文占满剩下的宽度。
private struct WatchReplyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.footnote)
            configuration.title
        }
    }
}
