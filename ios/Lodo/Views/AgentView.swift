import SwiftUI
import SwiftData
import PhotosUI
import LodoCore

/// 右下角"添加"按钮触发的 AI 对话页:持久保存多个 thread(左上角切换/新建),
/// 每轮请求真的带上前几轮对话历史;右下角语音、左侧 + 号传照片/文件。
/// 单条新建/修改叠一个 TaskEditView 在本页上面("表单即确认"这个体验保留),
/// 保存后往当前 thread 追加一条结果消息,不关掉聊天页。
struct AgentView: View {
    /// 弹出后是否尝试自动开始语音(还要看"点击添加自动开始语音"设置项,见 send() 前的判断)。
    let autoStart: Bool
    /// 解析并路由输入文本 + 最近对话历史;onThought 在 ReAct 循环中间步骤时被调用
    /// (如"正在查记忆…"),驱动 thinkingText 那条轻量提示。返回本页要展示的回应形态。
    /// 带上当前 thread 的 uuid——同时开着好几个 thread 时,批量操作确认/撤销
    /// 都要认清是哪个 thread 发起的,不能被另一个 thread 后来居上的一批覆盖。
    let submit: (
        String, UUID, [(role: String, content: String)], @escaping (String) -> Void
    ) async throws -> AgentReply
    /// 用户确认执行批量操作(操作暂存在 TodoListView),带上当前 thread uuid。
    let onConfirm: (UUID) -> Void
    /// 撤销上一批已执行的操作(TodoListView.performUndo),带上当前 thread uuid
    /// (核对撤销的是不是这个 thread 留下的那批),返回要展示给用户的回应文案;
    /// "已完成执行"气泡上的撤销按钮直接调这个,不用再走一遍文字指令。
    let onUndo: (UUID) -> AgentReply
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
    /// 发送中的请求;busy 时发送按钮变成取消,点了就 cancel 这个 Task。
    @State private var sendTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 打开页面默认唤起键盘,方便直接打字;autoStart 触发的自动语音不需要键盘,不抢焦点。
    @FocusState private var isInputFocused: Bool
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    @State private var showThreads = false
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false
    @State private var showMemoryPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var formTarget: FormTarget?

    init(prefill: String? = nil,
         autoStart: Bool = false,
         submit: @escaping (
            String, UUID, [(role: String, content: String)], @escaping (String) -> Void
         ) async throws -> AgentReply,
         onConfirm: @escaping (UUID) -> Void,
         onUndo: @escaping (UUID) -> AgentReply,
         saveTask: @escaping (TaskItem?, ParsedTask) -> Void) {
        self.autoStart = autoStart
        self.submit = submit
        self.onConfirm = onConfirm
        self.onUndo = onUndo
        self.saveTask = saveTask
        _text = State(initialValue: prefill ?? "")
    }

    private var activeThread: AgentThread? {
        if let uuid = currentThreadUUID, let match = threads.first(where: { $0.uuid == uuid }) {
            return match
        }
        return threads.first
    }

    /// 标题下面那行小字:服务商 + 思考强度(关闭时不提)+ 联网搜索是否已配置。
    private var aiModeSummary: String {
        var parts = [AppSettings.aiProvider]
        if AppSettings.thinkingLevel != "off" {
            // 不能简写成"思考+强度"("思考中"会被读成"正在思考"这个进行时状态,
            // 和思考强度=中撞了),用"强度思考"的顺序避开这个歧义。
            let label: String
            switch AppSettings.thinkingLevel {
            case "low": label = "低强度"
            case "high": label = "高强度"
            default: label = "中等"
            }
            parts.append("\(label)思考")
        }
        if WebSearchClient.isConfigured { parts.append("联网搜索") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let thread = activeThread {
                    VStack(spacing: 0) {
                        AgentMessageListView(thread: thread, onConfirmAction: handleConfirmAction,
                                            onUndo: handleUndo,
                                            onMemorizeSuggestion: handleMemorizeSuggestion,
                                            onExamplePrompt: { send(overrideText: $0) })
                            .id(thread.uuid)
                        thinkingRow
                        suggestionRow
                        attachmentChipsRow
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
                // 自定义 principal:标题下加一行当前 AI 模式(服务商/思考强度/
                // 联网搜索),不然用户在对话里完全看不出现在到底是哪个服务商、
                // 思考开没开、能不能联网搜索——这些都要跳回设置页才看得到。
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(activeThread?.title.isEmpty == false ? activeThread!.title : "AI 助手")
                            .font(.headline)
                        Text(aiModeSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
                allowsMultipleSelection: true
            ) { result in
                for url in (try? result.get()) ?? [] { handlePickedFile(url) }
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
            .sheet(isPresented: $showMemoryPicker) {
                MemoryPickerView(excluding: Set(pendingAttachments.compactMap(\.memoryUUID))) { picked in
                    for item in picked {
                        pendingAttachments.append(PendingAttachment(
                            displayName: item.title.isEmpty ? (item.originalFileName ?? "记忆条目") : item.title,
                            extractedText: item.sourceText, memoryUUID: item.uuid, symbol: item.kind.symbol))
                    }
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
            .onDisappear {
                speech.stop()
                discardUnsentAttachments()
            }
            .task {
                ensureThreadExists()
                refreshLatestMessage()
                if autoStart && AppSettings.agentAutoRecordOnOpen && !speech.isRecording {
                    typedPrefix = text
                    speech.toggle()
                } else {
                    isInputFocused = true
                }
                #if DEBUG
                seedDemoMessagesIfNeeded()
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-hascontent") {
                    text = "明天3点开会"
                }
                // 截图验证用:模拟请求进行中,发送按钮应该变成取消。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-busy") {
                    busy = true
                    thinkingText = "思考中…"
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

    /// 多附件横向胶囊行(文件/照片/从记忆库选的条目都可以并存),每个单独可移除。
    @ViewBuilder
    private var attachmentChipsRow: some View {
        if !pendingAttachments.isEmpty {
            HorizontalChipRow {
                ForEach(pendingAttachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        HStack(spacing: 4) {
            Label(attachment.displayName, systemImage: attachment.symbol)
                .font(.footnote)
                .lineLimit(1)
            Button {
                removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
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
                Button {
                    showMemoryPicker = true
                } label: {
                    Label("从记忆库选择", systemImage: "sparkles.rectangle.stack")
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
                    .focused($isInputFocused)
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
    /// (这时候是"停止"按钮),不能被发送按钮抢先弹出来。busy 期间发送按钮变成
    /// 取消,必须强制显示——不然请求一发出、输入框被清空,hasComposedContent
    /// 又变 false,取消按钮会被这条规则顶掉、换回(此时禁用的)麦克风按钮,
    /// 用户就没有取消入口了。
    private var showsInlineMic: Bool {
        !busy && (speech.isRecording || !hasComposedContent)
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

    /// busy 时按钮不再禁用,改成取消——点了就中断这次请求(输入区其余控件
    /// 如麦克风/附件继续保持 disabled(busy),不允许请求过程中改附件)。
    private var sendButton: some View {
        Button {
            if busy {
                cancelSend()
            } else {
                send()
            }
        } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 13 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(busy ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(busy ? "取消" : "发送")
    }

    private var hasComposedContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
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
            onConfirm(thread.uuid)
            appendAssistant(thread: thread, kind: .executed, content: "已完成执行")
        } else {
            appendAssistant(thread: thread, kind: .text, content: "已取消这次操作。")
        }
    }

    /// "已完成执行"气泡上的撤销按钮;结果(成功/没有可撤销的操作)追加成一条
    /// 新的回答消息,和用户直接打字"撤销"走同一条展示路径。传当前 thread 的
    /// uuid 给 onUndo 核对——这条按钮所在的气泡固然是"当前 thread 最新一条",
    /// 但 lastUndo 记的可能是别的 thread 后来执行的一批,对不上就不会真撤销。
    private func handleUndo() {
        guard let thread = activeThread else { return }
        if case .answer(let text, let related) = onUndo(thread.uuid) {
            appendAssistant(thread: thread, kind: .answer, content: text, relatedTitles: related)
        }
    }

    /// "收藏这条"按钮:AI 主动建议、用户确认后才真正落库,回执文案和用户直接
    /// 说"记住这个"走的 memorize 分支保持一致。
    private func handleMemorizeSuggestion(_ message: AgentMessage) {
        guard let thread = activeThread else { return }
        MemoryPipeline.saveText(message.content, context: context)
        appendAssistant(thread: thread, kind: .text,
                        content: "已收藏「\(MemorySearch.truncate(message.content, limit: 20))」,AI 正在整理成记忆条目。")
    }

    // MARK: - 附件

    private func handlePickedFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            let extraction = await ContentExtractor.extract(fileURL: url)
            let item = MemoryPipeline.saveFile(url, context: context)
            if scoped { url.stopAccessingSecurityScopedResource() }
            pendingAttachments.append(PendingAttachment(
                displayName: url.lastPathComponent, extractedText: extraction.text,
                memoryUUID: item?.uuid, symbol: item?.kind.symbol ?? "doc", isNewlyCreated: true))
        }
    }

    private func handlePickedImage(_ data: Data) {
        Task {
            let item = MemoryPipeline.saveImageData(data, context: context)
            var extractedText = ""
            if let item, let url = MemoryPipeline.fileURL(of: item) {
                extractedText = await ContentExtractor.extract(fileURL: url).text
            }
            pendingAttachments.append(PendingAttachment(
                displayName: "图片", extractedText: extractedText, memoryUUID: item?.uuid,
                symbol: "photo", isNewlyCreated: true))
        }
    }

    /// 移除一个待发送附件;如果它是刚为这次附件才存的记忆(拍照/选文件,
    /// 不是从记忆库里挑的已有条目),连同这条孤儿记忆一起删掉。
    private func removeAttachment(_ attachment: PendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        guard attachment.isNewlyCreated, let uuid = attachment.memoryUUID,
              let item = (try? context.fetch(FetchDescriptor<MemoryItem>(
                predicate: #Predicate<MemoryItem> { $0.uuid == uuid }))).flatMap(\.first) else { return }
        MemoryPipeline.delete(item, context: context)
    }

    /// 页面关闭时清掉还没发送就留下的孤儿记忆(拍了照/选了文件但没点发送、
    /// 也没手动移除 chip 就直接关掉了聊天页);从记忆库选的已有条目不受影响。
    private func discardUnsentAttachments() {
        for attachment in pendingAttachments where attachment.isNewlyCreated {
            guard let uuid = attachment.memoryUUID,
                  let item = (try? context.fetch(FetchDescriptor<MemoryItem>(
                    predicate: #Predicate<MemoryItem> { $0.uuid == uuid }))).flatMap(\.first)
            else { continue }
            MemoryPipeline.delete(item, context: context)
        }
        pendingAttachments = []
    }

    // MARK: - 提交

    private func send(overrideText: String? = nil) {
        let trimmed = (overrideText ?? text).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 0 || !pendingAttachments.isEmpty, !busy else { return }
        let thread = activeThread ?? {
            let new = AgentThread()
            context.insert(new)
            currentThreadUUID = new.uuid
            return new
        }()
        speech.stop()
        busy = true
        errorText = nil

        let attachments = pendingAttachments
        pendingAttachments = []
        text = ""

        let userMessage = AgentMessage(
            threadUUID: thread.uuid, role: .user, content: trimmed,
            attachmentMemoryUUIDs: attachments.compactMap(\.memoryUUID))
        context.insert(userMessage)
        // 首轮对话:先用截断兜底,立刻有个标题;拿到 AI 回复后再尝试换成真正的总结标题
        // (刚打开时导航栏显示"AI 助手",这里是它第一次变成 thread 标题的地方)。
        let isFirstMessage = thread.title.isEmpty
        if isFirstMessage {
            let seed = trimmed.isEmpty ? (attachments.first?.displayName ?? "") : trimmed
            thread.title = MemorySearch.truncate(seed, limit: 20)
        }
        thread.updatedAt = Date()
        try? context.save()
        latestMessage = userMessage

        let history = recentHistory(in: thread, excluding: userMessage)
        var outgoing = trimmed
        for attachment in attachments {
            outgoing += "\n\n[附件:\(attachment.displayName)]\n\(attachment.extractedText)"
        }

        // 请求一发出就显示"思考中…";ReAct 工具调用会用更具体的提示
        // (如"正在查记忆…")覆盖它,交换结束后统一在 defer 里清空。
        if AppSettings.thinkingLevel != "off" {
            thinkingText = "思考中…"
        }
        sendTask = Task {
            defer {
                busy = false
                thinkingText = nil
                sendTask = nil
            }
            do {
                let reply = try await submit(outgoing, thread.uuid, history) { thought in
                    thinkingText = thought
                }
                // 拿到结果时可能已经被用户取消——不再落库/弹表单,避免取消瞬间
                // 又把回应加回来。
                guard !Task.isCancelled else { return }
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
                case .suggestMemorize(let text):
                    appendAssistant(thread: thread, kind: .memorizeSuggestion, content: text)
                }
                if isFirstMessage {
                    refineThreadTitle(thread: thread, userText: trimmed, reply: reply)
                }
            } catch {
                // 用户主动取消不算错误,不弹提示;DeepSeekClient 的 URLSession
                // async 请求本身就会随 Task 取消抛 CancellationError,不用额外
                // 传取消信号进 submit。
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorText = error.localizedDescription
            }
        }
    }

    private func cancelSend() {
        sendTask?.cancel()
        sendTask = nil
        busy = false
        thinkingText = nil
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
        case .suggestMemorize(let text): return text
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
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-executed") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "把开会删了"))
            appendAssistant(thread: thread, kind: .executed, content: "已完成执行")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-memorize-suggestion") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "我周三下午一般没空"))
            appendAssistant(thread: thread, kind: .memorizeSuggestion, content: "用户周三下午通常没有空闲时间")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-threads") {
            for title in ["记住wifi密码是8888", "我想去香山爬山"] {
                let extra = AgentThread()
                extra.title = title
                extra.updatedAt = Date().addingTimeInterval(-Double.random(in: 3600...300000))
                context.insert(extra)
                context.insert(AgentMessage(threadUUID: extra.uuid, role: .user, content: title))
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

/// 待发送的附件暂存(可以有多个);新拍的文件/照片发送前已经落进"记忆"
/// (memoryUUID),从记忆库里选的本来就有 uuid——两种来源统一走这一份载体。
/// extractedText 是已经跑过 ContentExtractor 提取或记忆条目自带的原文,
/// 发送时拼进这一轮请求。
private struct PendingAttachment: Identifiable {
    let id = UUID()
    var displayName: String
    var extractedText: String
    var memoryUUID: UUID?
    var symbol: String = "paperclip"
    /// true = 这条记忆是刚为这次附件才存的(拍照/选文件);移除这个 chip 时
    /// 要把这条孤儿记忆一并删掉,不然用户没发送就把它删了,记忆库里却平白
    /// 多出一条。false = 从记忆库里选的已有条目,移除 chip 不影响原条目。
    var isNewlyCreated: Bool = false
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
    let onUndo: () -> Void
    let onMemorizeSuggestion: (AgentMessage) -> Void
    let onExamplePrompt: (String) -> Void

    @Query private var messages: [AgentMessage]

    init(thread: AgentThread, onConfirmAction: @escaping (AgentMessage, Bool) -> Void,
         onUndo: @escaping () -> Void, onMemorizeSuggestion: @escaping (AgentMessage) -> Void,
         onExamplePrompt: @escaping (String) -> Void) {
        self.thread = thread
        self.onConfirmAction = onConfirmAction
        self.onUndo = onUndo
        self.onMemorizeSuggestion = onMemorizeSuggestion
        self.onExamplePrompt = onExamplePrompt
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
                            onCancelConfirm: { onConfirmAction(message, false) },
                            onUndo: onUndo,
                            onMemorizeSuggestion: { onMemorizeSuggestion(message) })
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

    private static let examplePrompts = [
        "明天下午3点开会", "我之前存的 wifi 密码是多少", "帮我整理一下今天的安排",
    ]

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "开始对话", systemImage: "sparkles",
                description: Text("说一句话或打字,新建/修改/完成/删除事项,收藏内容或问问你存过的记忆。"))
            VStack(spacing: 8) {
                ForEach(Self.examplePrompts, id: \.self) { prompt in
                    Button(prompt) { onExamplePrompt(prompt) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
