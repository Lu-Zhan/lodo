import SwiftUI
import SwiftData
import PhotosUI
import LodoCore

/// 右下角"添加"按钮触发的 AI 对话页:持久保存多个 thread(左上角切换/新建),
/// 每轮请求真的带上前几轮对话历史;右下角语音、左侧 + 号传照片/文件。
/// 单条新建/修改叠一个 TaskEditView 在本页上面("表单即确认"这个体验保留),
/// 保存后往当前 thread 追加一条结果消息,不关掉聊天页。
struct AgentView: View {
    /// 弹出后是否自动开始语音(右下角键长按触发时为 true)。
    let autoStart: Bool
    /// 解析并路由输入文本 + 最近对话历史;onThought 在 ReAct 循环中间步骤时被调用
    /// (如"正在查记忆…"),驱动 thinkingText 那条轻量提示。返回本页要展示的回应形态。
    let submit: (
        String, [(role: String, content: String)], @escaping (String) -> Void
    ) async throws -> AgentReply
    /// 用户确认执行批量操作(操作暂存在 TodoListView)。
    let onConfirm: () -> Void
    /// 单条新建/修改保存,existing 为 nil 表示新建。
    let saveTask: (TaskItem?, ParsedTask) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]

    @State private var currentThreadUUID: UUID?
    /// 当前 thread 最新一条消息;驱动建议行(clarify 才出现)。
    @State private var latestMessage: AgentMessage?
    /// ReAct 循环中间步骤的轻量提示(如"正在查记忆…");不落库,循环一结束就清空。
    @State private var thinkingText: String?

    @State private var text: String
    @State private var busy = false
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    @State private var showThreads = false
    @State private var pendingAttachment: PendingAttachment?
    @State private var showFileImporter = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var formTarget: FormTarget?

    init(prefill: String? = nil,
         autoStart: Bool = false,
         submit: @escaping (
            String, [(role: String, content: String)], @escaping (String) -> Void
         ) async throws -> AgentReply,
         onConfirm: @escaping () -> Void,
         saveTask: @escaping (TaskItem?, ParsedTask) -> Void) {
        self.autoStart = autoStart
        self.submit = submit
        self.onConfirm = onConfirm
        self.saveTask = saveTask
        _text = State(initialValue: prefill ?? "")
    }

    private var activeThread: AgentThread? {
        if let uuid = currentThreadUUID, let match = threads.first(where: { $0.uuid == uuid }) {
            return match
        }
        return threads.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let thread = activeThread {
                    VStack(spacing: 0) {
                        AgentMessageListView(thread: thread, onConfirmAction: handleConfirmAction)
                            .id(thread.uuid)
                        thinkingRow
                        suggestionRow
                        if let pendingAttachment {
                            attachmentChip(pendingAttachment)
                        }
                        if let error = errorText ?? speech.errorText {
                            Text(error).font(.footnote).foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                        inputBar
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(activeThread?.title.isEmpty == false ? activeThread!.title : "AI 助手")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showThreads = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("对话列表")
                    .popover(isPresented: $showThreads) {
                        AgentThreadListView(currentThreadUUID: $currentThreadUUID) {
                            showThreads = false
                            refreshLatestMessage()
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        speech.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭")
                }
            }
            .sheet(item: $formTarget) { target in
                TaskEditView(existing: target.existing, parsed: target.parsed,
                             attachment: target.existing?.attachment) { savedParsed in
                    saveTask(target.existing, savedParsed)
                    if let thread = activeThread {
                        let verb = target.existing == nil ? "已新建" : "已修改"
                        appendAssistant(
                            thread: thread, kind: .text,
                            content: "\(verb):\(savedParsed.title)(\(TaskItem.format(savedParsed.remindAt)))")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .plainText, .presentation, .data],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first else { return }
                handlePickedFile(url)
            }
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        handlePickedImage(data)
                    }
                    photoSelection = nil
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if !transcript.isEmpty { text = typedPrefix + transcript }
            }
            .onChange(of: speech.isRecording) { was, isRecording in
                // 讲完话(录音停止)稍等最终转写落定后自动提交
                if was && !isRecording && !busy && errorText == nil {
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        send()
                    }
                }
            }
            .onChange(of: currentThreadUUID) { _, _ in refreshLatestMessage() }
            .onDisappear { speech.stop() }
            .task {
                ensureThreadExists()
                refreshLatestMessage()
                if autoStart && AppSettings.agentAutoRecordOnOpen && !speech.isRecording {
                    typedPrefix = text
                    speech.toggle()
                }
                #if DEBUG
                seedDemoMessagesIfNeeded()
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-hascontent") {
                    text = "明天3点开会"
                }
                #endif
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    // MARK: - ReAct 中间步骤的轻量提示

    @ViewBuilder
    private var thinkingRow: some View {
        if let thinkingText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(thinkingText).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    // MARK: - 建议行(clarify 候选,参考 Claude app 放输入框上方,不嵌进气泡)

    @ViewBuilder
    private var suggestionRow: some View {
        if let latestMessage, latestMessage.role == .assistant, latestMessage.kind == .clarify,
           !latestMessage.clarifyOptions.isEmpty {
            HorizontalChipRow {
                ForEach(latestMessage.clarifyOptions, id: \.self) { option in
                    Button(option) { send(overrideText: option) }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 输入栏

    private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        HStack {
            Label(attachment.displayName, systemImage: "paperclip")
                .font(.footnote)
                .lineLimit(1)
            Spacer()
            Button {
                pendingAttachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// 参考 iMessage 的输入栏:+ 号独立圆按钮;文本框是一个玻璃胶囊,没在打字/
    /// 正在录音时右侧嵌一个麦克风(点了直接开始/停止录音);一旦有内容待发送
    /// (打字或已选好附件),麦克风让位,胶囊外侧另弹出一个独立的蓝色圆形发送
    /// 按钮——这正是 iMessage 输入框"麦克风 ↔ 独立发送按钮"的切换方式,
    /// 不是同一个位置换图标。
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("照片", systemImage: "photo")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("文件", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glassBackground(Circle())
            }
            .disabled(busy)
            .accessibilityLabel("添加附件")

            HStack(spacing: 8) {
                TextField("说点什么…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit { send() }

                if showsInlineMic {
                    inlineMicButton
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, showsInlineMic ? 8 : 16)
            .padding(.vertical, 8)
            .glassBackground(Capsule())

            if !showsInlineMic {
                sendButton
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: showsInlineMic)
        .padding()
    }

    /// 正在录音时即便文字已经有内容(实时转写填进了输入框)也继续显示麦克风
    /// (这时候是"停止"按钮),不能被发送按钮抢先弹出来。
    private var showsInlineMic: Bool {
        speech.isRecording || !hasComposedContent
    }

    private var inlineMicButton: some View {
        Button {
            if speech.isRecording {
                speech.stop()
            } else {
                typedPrefix = text
                speech.toggle()
            }
        } label: {
            Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18))
                .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .disabled(busy)
        .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("发送")
    }

    private var hasComposedContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || pendingAttachment != nil
    }

    // MARK: - Thread/消息

    private func ensureThreadExists() {
        guard threads.isEmpty else { return }
        let thread = AgentThread()
        context.insert(thread)
        try? context.save()
        currentThreadUUID = thread.uuid
    }

    private func refreshLatestMessage() {
        guard let thread = activeThread else {
            latestMessage = nil
            return
        }
        let uuid = thread.uuid
        latestMessage = try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> { $0.threadUUID == uuid },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])).first
    }

    private func recentHistory(in thread: AgentThread, excluding: AgentMessage) -> [(role: String, content: String)] {
        let threadUUID = thread.uuid
        let excludeUUID = excluding.uuid
        let all = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> { $0.threadUUID == threadUUID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return all.filter { $0.uuid != excludeUUID }.suffix(16)
            .map { (role: $0.roleRaw, content: $0.content) }
    }

    @discardableResult
    private func appendAssistant(
        thread: AgentThread, kind: AgentMessageKind, content: String,
        relatedTitles: [String] = [], clarifyOptions: [String] = []
    ) -> AgentMessage {
        let message = AgentMessage(threadUUID: thread.uuid, role: .assistant, kind: kind,
                                   content: content, relatedTitles: relatedTitles,
                                   clarifyOptions: clarifyOptions)
        context.insert(message)
        thread.updatedAt = Date()
        try? context.save()
        latestMessage = message
        return message
    }

    private func handleConfirmAction(_ message: AgentMessage, execute: Bool) {
        guard let thread = activeThread else { return }
        if execute {
            onConfirm()
            appendAssistant(thread: thread, kind: .text, content: "已完成执行。")
        } else {
            appendAssistant(thread: thread, kind: .text, content: "已取消这次操作。")
        }
    }

    // MARK: - 附件

    private func handlePickedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            let extraction = await ContentExtractor.extract(fileURL: url)
            let item = MemoryPipeline.saveFile(url, context: context)
            if scoped { url.stopAccessingSecurityScopedResource() }
            pendingAttachment = PendingAttachment(
                displayName: url.lastPathComponent, extractedText: extraction.text,
                memoryUUID: item?.uuid)
        }
    }

    private func handlePickedImage(_ data: Data) {
        Task {
            let item = MemoryPipeline.saveImageData(data, context: context)
            var extractedText = ""
            if let item, let url = MemoryPipeline.fileURL(of: item) {
                extractedText = await ContentExtractor.extract(fileURL: url).text
            }
            pendingAttachment = PendingAttachment(
                displayName: "图片", extractedText: extractedText, memoryUUID: item?.uuid)
        }
    }

    // MARK: - 提交

    private func send(overrideText: String? = nil) {
        let trimmed = (overrideText ?? text).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 0 || pendingAttachment != nil, !busy else { return }
        let thread = activeThread ?? {
            let new = AgentThread()
            context.insert(new)
            currentThreadUUID = new.uuid
            return new
        }()
        speech.stop()
        busy = true
        errorText = nil

        let attachment = pendingAttachment
        pendingAttachment = nil
        text = ""

        let userMessage = AgentMessage(
            threadUUID: thread.uuid, role: .user, content: trimmed,
            attachmentMemoryUUID: attachment?.memoryUUID)
        context.insert(userMessage)
        // 首轮对话:先用截断兜底,立刻有个标题;拿到 AI 回复后再尝试换成真正的总结标题
        // (刚打开时导航栏显示"AI 助手",这里是它第一次变成 thread 标题的地方)。
        let isFirstMessage = thread.title.isEmpty
        if isFirstMessage {
            let seed = trimmed.isEmpty ? (attachment?.displayName ?? "") : trimmed
            thread.title = MemorySearch.truncate(seed, limit: 20)
        }
        thread.updatedAt = Date()
        try? context.save()
        latestMessage = userMessage

        let history = recentHistory(in: thread, excluding: userMessage)
        var outgoing = trimmed
        if let attachment {
            outgoing += "\n\n[附件:\(attachment.displayName)]\n\(attachment.extractedText)"
        }

        Task {
            defer {
                busy = false
                thinkingText = nil
            }
            do {
                let reply = try await submit(outgoing, history) { thought in
                    thinkingText = thought
                }
                switch reply {
                case .routeToForm(let existing, let parsed):
                    formTarget = FormTarget(existing: existing, parsed: parsed)
                case .confirm(let lines):
                    appendAssistant(thread: thread, kind: .confirm, content: lines.joined(separator: "\n"))
                case .clarify(let question, let options):
                    appendAssistant(thread: thread, kind: .clarify, content: question,
                                    clarifyOptions: options)
                case .answer(let text, let related):
                    appendAssistant(thread: thread, kind: .answer, content: text, relatedTitles: related)
                }
                if isFirstMessage {
                    refineThreadTitle(thread: thread, userText: trimmed, reply: reply)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// 首轮对话拿到回复后,尝试用 AI 把标题从"原话截断"换成真正的总结标题;
    /// 尽力而为——没配置 AI/请求失败时保留截断版标题,不影响使用。
    private func refineThreadTitle(thread: AgentThread, userText: String, reply: AgentReply) {
        guard DeepSeekClient.isConfigured else { return }
        let assistantText = Self.summaryInput(for: reply)
        let combined = "用户:\(userText)" + (assistantText.isEmpty ? "" : "\n助手:\(assistantText)")
        Task { @MainActor in
            guard let title = try? await DeepSeekClient.summarizeThreadTitle(combined) else { return }
            thread.title = title
            try? context.save()
        }
    }

    private static func summaryInput(for reply: AgentReply) -> String {
        switch reply {
        case .routeToForm(_, let parsed): return "新建/修改了事项:\(parsed.title)"
        case .confirm(let lines): return lines.joined(separator: ";")
        case .clarify(let question, _): return question
        case .answer(let text, _): return text
        }
    }

    #if DEBUG
    /// 截图验证用:模拟确认清单 / 反问 / 回答三种回应态。
    private func seedDemoMessagesIfNeeded() {
        guard let thread = activeThread else { return }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-confirm") {
            appendAssistant(thread: thread, kind: .confirm,
                            content: "新建:开周会(明天 15:00 · 60 分钟)\n完成:给妈妈回电话\n删除:取快递")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-clarify") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "提醒我交材料"))
            appendAssistant(thread: thread, kind: .clarify, content: "什么时候提醒你交材料?",
                            clarifyOptions: ["明天 09:00", "明天 14:00", "今晚 20:00"])
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-answer") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "我之前存的 wifi 密码"))
            appendAssistant(thread: thread, kind: .answer, content: "你收藏的 wifi 密码是 8888。",
                            relatedTitles: ["家里 wifi 密码"])
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-threads") {
            for title in ["记住wifi密码是8888", "我想去香山爬山"] {
                let extra = AgentThread()
                extra.title = title
                extra.updatedAt = Date().addingTimeInterval(-Double.random(in: 3600...300000))
                context.insert(extra)
            }
            try? context.save()
            // popover 挂在工具栏按钮上,当帧触发不生效,延后一点再弹(与记忆筛选按钮同款问题)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showThreads = true
            }
        }
    }
    #endif
}

/// 待发送的附件暂存;发送前已经落进"记忆"(memoryUUID),extractedText 是
/// 已经跑过 ContentExtractor 的结果,发送时拼进这一轮请求。
private struct PendingAttachment {
    var displayName: String
    var extractedText: String
    var memoryUUID: UUID?
}

/// 单条新建/修改弹出的表单目标。
private struct FormTarget: Identifiable {
    let id = UUID()
    let existing: TaskItem?
    let parsed: ParsedTask
}

/// 消息列表:按 thread 建 @Query(SwiftData 动态 predicate 的标准写法——
/// 父视图用 .id(thread.uuid) 强制这个子视图在切换 thread 时重建)。
private struct AgentMessageListView: View {
    let thread: AgentThread
    let onConfirmAction: (AgentMessage, Bool) -> Void

    @Query private var messages: [AgentMessage]

    init(thread: AgentThread, onConfirmAction: @escaping (AgentMessage, Bool) -> Void) {
        self.thread = thread
        self.onConfirmAction = onConfirmAction
        let uuid = thread.uuid
        _messages = Query(filter: #Predicate<AgentMessage> { $0.threadUUID == uuid },
                          sort: [SortDescriptor(\.createdAt)])
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        AgentMessageBubble(
                            message: message, isLatest: message.uuid == messages.last?.uuid,
                            onConfirm: { onConfirmAction(message, true) },
                            onCancelConfirm: { onConfirmAction(message, false) })
                        .id(message.uuid)
                    }
                }
                .padding()
                .animation(.snappy, value: messages.count)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.uuid, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.uuid, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "开始对话", systemImage: "sparkles",
            description: Text("说一句话或打字,新建/修改/完成/删除事项,收藏内容或问问你存过的记忆。"))
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
