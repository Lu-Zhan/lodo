import SwiftUI
import SwiftData
import PhotosUI
import LodoCore
#if os(iOS)
import UIKit
#endif

/// AI 对话页(抽屉里的四个平级页面之一):持久保存多个 thread(在侧栏切换/新建),
/// 每轮请求真的带上前几轮对话历史;右下角语音、左侧 + 号传照片/文件。
/// 单条新建/修改叠一个 TaskEditView 在本页上面("表单即确认"这个体验保留),
/// 保存后往当前 thread 追加一条结果消息,不关掉聊天页。
/// 对话列表和抽屉本身归外壳(AppShellView/AppSidebarView),这里只管聊天区。
struct AgentView: View {
    /// 非 nil 时把文本预填进输入框(深链/Siri 交接/小组件"+"),消费后置 nil。
    @Binding var pendingPrefill: String?
    /// 当前对话。外壳持有——侧栏的对话历史列表和这里看的是同一个值。
    @Binding var currentThreadUUID: UUID?
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
    /// 抽屉推开/拖拽过程中要淡出导航栏上的标题(见 body 的 .toolbar);
    /// 判据由外壳算好经 Environment 下发,这里不重复一套。
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.colorScheme) private var colorScheme

    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]

    /// ReAct 循环中间步骤的轻量提示(如"正在查记忆…");不落库,循环一结束就清空。
    @State private var thinkingText: String?

    @State private var text = ""
    @State private var busy = false
    /// 发送中的请求;busy 时发送按钮变成取消,点了就 cancel 这个 Task。
    @State private var sendTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 打开页面默认唤起键盘,方便直接打字;语音改成手动点麦克风图标触发。
    @FocusState private var isInputFocused: Bool
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""
    /// 长按气泡选了"引用"后待发送的那条消息;输入框上方的引用预览行据此渲染,
    /// 发送时会把它的文本折进 outgoing(不写回气泡展示用的 content)。
    @State private var quotedMessage: AgentMessage?
    /// 长按气泡选了"修改"后待确认的目标;只是打开确认弹窗,真正的截断删除
    /// 发生在用户在 confirmationDialog 里点确认之后。
    @State private var pendingEdit: AgentMessage?

    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false
    @State private var showMemoryPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var formTarget: FormTarget?
    /// 小彩蛋:输入框内容恰好是 "0707"(气球生日祝福)或 "0829"(结婚一周年,
    /// 爱心)时弹一个全屏动画,见下面的 .onChange(of: text) 和 EasterEggView。
    @State private var showEasterEgg = false
    @State private var easterEggOccasion: EasterEggView.Occasion = .birthday

    /// @State 属性都是 private,合成的 memberwise init 会跟着降级成 private、
    /// 别的文件用不了,所以显式写一个。
    init(pendingPrefill: Binding<String?>,
         currentThreadUUID: Binding<UUID?>,
         submit: @escaping (
            String, UUID, [(role: String, content: String)], @escaping (String) -> Void
         ) async throws -> AgentReply,
         onConfirm: @escaping (UUID) -> Void,
         onUndo: @escaping (UUID) -> AgentReply,
         saveTask: @escaping (TaskItem?, ParsedTask) -> Void) {
        self._pendingPrefill = pendingPrefill
        self._currentThreadUUID = currentThreadUUID
        self.submit = submit
        self.onConfirm = onConfirm
        self.onUndo = onUndo
        self.saveTask = saveTask
    }

    /// 消费外壳递进来的预填文本。空串表示"只是把页面切过来",不覆盖用户已经
    /// 打了一半的内容(和原来 prefill 为空时不动 text 的行为一致)。
    private func consumePrefill() {
        guard let request = pendingPrefill else { return }
        pendingPrefill = nil
        if !request.isEmpty { text = request }
        isInputFocused = true
    }

    private var activeThread: AgentThread? {
        if let uuid = currentThreadUUID, let match = threads.first(where: { $0.uuid == uuid }) {
            return match
        }
        return threads.first
    }

    /// 标题栏正标题:当前对话的标题(首轮消息后换成 AI 总结的那版);还没发过
    /// 消息的空 thread 用和侧栏列表一致的"新对话"占位。
    private var hidesToolbarChrome: Bool { sidebarChrome?.hidesChrome ?? false }

    private var threadTitle: String {
        let title = activeThread?.title ?? ""
        return title.isEmpty ? "新对话" : title
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
            chatColumn
            // 这里曾经 .ignoresSafeArea(.container, edges: .bottom),让输入栏贴到
            // 屏幕物理底边、不给 home indicator 留白边。现在整页底色由 AppShellView
            // 统一铺到物理边缘了,那条"死白边"本来就不存在;继续贴底反而有害:抽屉
            // 推开时页面被裁成 44pt 圆角,输入栏自己 26pt 的玻璃圆角正好落进那个圆角
            // 里,两道弧线套在一起。让输入栏收回安全区之上即可(消息仍然从它背后滚
            // 过去,底部那截不是死区)。
            .navigationTitle(threadTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // 自定义 principal:标题栏显示当前对话的总结标题(首轮消息后由
                // summarizeThreadTitle 生成,在此之前是原话截断);标题下加一行
                // 当前 AI 模式(服务商/思考强度/联网搜索),不然用户在对话里完全
                // 看不出现在到底是哪个服务商、思考开没开、能不能联网搜索——
                // 这些都要跳回设置页才看得到。
                // principal 项恒定渲染(只淡出内容),抽屉展开/拖拽时导航栏高度
                // 才不会跟着两行标题的消失/出现联动跳变,chatColumn 紧贴在导航栏
                // 下方布局,导航栏一变高聊天区就会跟着窜一下——这是纯文字 VStack,
                // 没有 Liquid Glass 背景,可以放心用 opacity(☰ 那颗不行,它带
                // 系统画的 Liquid Glass 底,见 sidebarToolbarButton 的注释)。
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(threadTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(aiModeSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .opacity(hidesToolbarChrome ? 0 : 1)
                    .accessibilityHidden(hidesToolbarChrome)
                }
            }
            .sidebarToolbarButton()
            .sheet(item: $formTarget) { target in
                TaskEditView(existing: target.existing, parsed: target.parsed,
                             attachment: target.existing?.attachment) { savedParsed in
                    saveTask(target.existing, savedParsed)
                    if let thread = activeThread {
                        appendTaskResult(
                            thread: thread, existingUUID: target.existing?.uuid,
                            parsed: savedParsed)
                    }
                }
            }
            .confirmationDialog(
                "修改这条消息?", isPresented: Binding(
                    get: { pendingEdit != nil }, set: { if !$0 { pendingEdit = nil } }
                ), titleVisibility: .visible
            ) {
                Button("修改", role: .destructive) {
                    if let message = pendingEdit { performEdit(message) }
                    pendingEdit = nil
                }
            } message: {
                Text("之后的对话记录会一并删除,不可恢复。")
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
            // macOS 没有 fullScreenCover(API 本身就不可用),用窗口 sheet 代替。
            #if os(iOS)
            .fullScreenCover(isPresented: $showEasterEgg) {
                EasterEggView(occasion: easterEggOccasion)
            }
            #else
            .sheet(isPresented: $showEasterEgg) {
                EasterEggView(occasion: easterEggOccasion)
            }
            #endif
            .onChange(of: text) { _, newValue in
                switch newValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "0707":
                    text = ""
                    easterEggOccasion = .birthday
                    showEasterEgg = true
                case "0829":
                    text = ""
                    easterEggOccasion = .anniversary
                    showEasterEgg = true
                default:
                    break
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if !transcript.isEmpty { text = typedPrefix + transcript }
            }
            .onChange(of: speech.isRecording) { was, isRecording in
                // 讲完话(录音停止)稍等最终转写落定后自动提交。云端引擎不用这条:
                // 停止录音那一刻转写还没开始,text 仍是空的,真正该发送的时机是
                // 下面 isProcessing 变回 false 那一刻(转写结果已经落进 text)——
                // 这两条严格分工,不能都对云端引擎生效,否则空 text 会先把
                // 附件(如果有)提前发出去,漏掉随后才到的语音文字。
                guard AppSettings.sttEngine != "qwenASR" else { return }
                if was && !isRecording && !busy && errorText == nil {
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        send()
                    }
                }
            }
            .onChange(of: speech.isProcessing) { was, isProcessing in
                // 云端引擎专用:转写请求刚结束(录音早已停止),没出错就自动提交。
                if was && !isProcessing && !speech.isRecording && !busy && errorText == nil {
                    send()
                }
            }
            .onDisappear {
                speech.stop()
                discardUnsentAttachments()
            }
            .task {
                ensureThreadExists()
                isInputFocused = true
                consumePrefill()
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
                // 截图验证用:直接把 isRecording 摆成 true,不真的起录音——
                // simctl 没有麦克风可触发,用来看麦克风按钮的呼吸动效。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-recording") {
                    speech.isRecording = true
                }
                // 截图验证用:直接弹彩蛋全屏页(simctl 没法打字触发 0707/0829)。
                if ProcessInfo.processInfo.arguments.contains("--demo-easter-egg") {
                    easterEggOccasion = .birthday
                    showEasterEgg = true
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-easter-egg-anniversary") {
                    easterEggOccasion = .anniversary
                    showEasterEgg = true
                }
                // 截图验证用:塞几条历史对话把侧栏列表填出来(推开抽屉那步由
                // AppShellView 的 --demo-agent-sidebar/--demo-sidebar 负责)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-sidebar") {
                    seedDemoThreads()
                    isInputFocused = false
                }
                // 截图验证用:模拟长按气泡选了"引用"——simctl 没法长按弹
                // contextMenu,直接把状态摆出来看输入框上方的预览行(超长文本
                // 单行省略号截断)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-quote-preview"),
                   let thread = activeThread {
                    let quoted = AgentMessage(
                        threadUUID: thread.uuid, role: .assistant,
                        content: "你收藏的 wifi 密码是 8888,这是一段特意写得很长很长用来测试单行省略号截断效果的引用预览文本。")
                    context.insert(quoted)
                    try? context.save()
                    quotedMessage = quoted
                }
                // 截图验证用:模拟长按气泡选了"修改"——直接弹出截断确认弹窗
                // (simctl 没法长按+点菜单项)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-edit-confirm"),
                   let thread = activeThread {
                    let target = AgentMessage(threadUUID: thread.uuid, role: .user, content: "明天下午3点开会")
                    context.insert(target)
                    context.insert(AgentMessage(threadUUID: thread.uuid, role: .assistant, kind: .text,
                                                content: "好的,已经帮你记下明天下午3点开会。"))
                    try? context.save()
                    pendingEdit = target
                }
                #endif
            }
        }
        .onChange(of: pendingPrefill) { _, _ in consumePrefill() }
    }

    // MARK: - 聊天区

    /// 消息列表 + 输入栏这一整块。
    @ViewBuilder
    private var chatColumn: some View {
        if let thread = activeThread {
            // 输入栏这坨挂在 ScrollView 的 safeAreaInset(而不是跟消息列表
            // 平铺在同一个 VStack 里),消息才会真的滚到它背后。参考系统
            // Messages/语音备忘录的输入栏:这块区域本身不铺任何背景色——
            // +/文本框/麦克风三个控件各自是独立的 Liquid Glass 胶囊(见
            // inputBar),控件之间、控件下方一路到屏幕真实底边都是真透明,
            // 露出的是聊天内容本身,不是另一块单独的磨砂色块。
            AgentMessageListView(thread: thread, onConfirmAction: handleConfirmAction,
                                onUndo: handleUndo,
                                onMemorizeSuggestion: handleMemorizeSuggestion,
                                onTaskProposalConfirm: handleTaskProposalConfirm,
                                onTaskProposalCancel: handleTaskProposalCancel,
                                onTaskProposalTap: handleTaskProposalTap,
                                onAskSubmit: handleAskSubmit,
                                onAskCancel: handleAskCancel,
                                onExamplePrompt: { send(overrideText: $0) },
                                onCopy: copyMessageContent,
                                onQuote: quoteMessage,
                                onEdit: requestEdit)
                .id(thread.uuid)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        thinkingRow
                        attachmentChipsRow
                        quotedPreviewRow
                        if let error = errorText ?? speech.errorText {
                            Text(error).font(.footnote).foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                        inputBar
                    }
                }
        } else {
            ProgressView()
        }
    }

    // MARK: - ReAct 中间步骤的轻量提示

    @ViewBuilder
    private var thinkingRow: some View {
        if let thinkingText {
            ShimmerText(text: thinkingText)
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.opacity)
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

    /// 长按气泡选"引用"后,输入框上方出现的单行预览:超长文本尾部省略号截断,
    /// 右侧 X 取消引用。一次只会有一条引用,所以是独立整行,不走多附件那套
    /// HorizontalChipRow。
    @ViewBuilder
    private var quotedPreviewRow: some View {
        if let quoted = quotedMessage {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(.secondary)
                Text(quoted.content)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    quotedMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
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

    /// 参考 Claude app 的输入栏:一整块合并的磨砂卡片悬浮在内容上方(四周留白,
    /// 不贴屏幕物理边缘)。非录音态(composingBar)卡片内竖直分两行——上面纯
    /// 文本输入框(没有自己的胶囊背景,直接落在卡片底色上),下面是控件行:
    /// 左边 + 号纯图标(无背景),右边麦克风/发送纯图标或强调色圆按钮,没在
    /// 打字时是麦克风(点了开始录音);一旦有内容待发送,同一个槽位换成强调色
    /// 发送按钮——是"麦克风 ↔ 独立发送按钮"互斥切换,不是文本框内嵌图标。只有
    /// 发送/停止这一个控件保留实心玻璃填充,+/麦克风都是纯图标,靠卡片本身的
    /// 玻璃背景衬底,不需要各自再套一层——因此不再需要 `GlassEffectContainer`:
    /// 那是给多个相邻独立玻璃形状互相感知融合用的,现在只剩"一张卡 + 一个独立
    /// 强调色按钮",`.glassProminentButton()` 已经能正确渲染自己的玻璃层,不需要
    /// 外层容器配合。录音态(recordingBar)整条换成"取消 / 波形 / 确认"三段式,
    /// 同一张卡片容器,不再有文本框/+/麦克风。
    private var inputBar: some View {
        inputBarRow
    }

    private var inputBarRow: some View {
        Group {
            if speech.isRecording {
                recordingBar
                    .transition(.scale.combined(with: .opacity))
            } else {
                composingBar
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.lodoAware(.snappy(duration: 0.2)), value: speech.isRecording)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.composerRadius, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// 输入栏控件行的固定高度(+ / 麦克风 / 识别中 三个都按它取 frame)。
    private static let composerControlSize: CGFloat = 36

    private var composingBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("试试加入一个待办/记忆…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { send() }
                // 只在真的是"敲一个字/删一个字"(前后字数差 1)时振动——程序化
                // 整段赋值(发送后清空、引用/修改回填、语音听写追加一大段)
                // 一次性变化好几个字,不算"逐字输入",不触发。
                .onChange(of: text) { oldValue, newValue in
                    if abs(newValue.count - oldValue.count) == 1 {
                        Haptics.tick()
                    }
                }

            HStack(alignment: .center, spacing: 8) {
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
                        // 没有背景形状后,点击区默认会缩成图标本身的紧凑边界——
                        // 用 contentShape 把 36×36 的点击热区找回来。
                        .contentShape(Rectangle())
                }
                .disabled(busy)
                .accessibilityLabel("添加附件")

                Spacer()

                if speech.isProcessing {
                    speechProcessingIndicator
                        .transition(.scale.combined(with: .opacity))
                } else if showsInlineMic {
                    inlineMicButton
                        .transition(.scale.combined(with: .opacity))
                } else {
                    sendButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // 行高定死在按钮那一档:发送键是 iOS 26 的 Liquid Glass 圆钮,系统按
            // 自己的最小触控尺寸布局、不理会下游的 frame 收窄(见 sendButton 的
            // 注释),比左边 +/麦克风高出十点左右。不定死的话打字的第一下就会
            // 因为"麦克风换成发送键"把整张输入卡顶高一截,文本框跟着往上跳——
            // 打字时**只该换那颗按钮**,输入框不能动。定死之后发送键仍按自己的
            // 尺寸绘制(超出的几点落在卡片本来就有的内边距里),只是不再参与
            // 撑高这一行。
            .frame(height: Self.composerControlSize)
            .animation(.lodoAware(.snappy(duration: 0.2)), value: showsInlineMic)
            .animation(.lodoAware(.snappy(duration: 0.2)), value: speech.isProcessing)
        }
    }

    /// 录音时整条输入条换成的"取消 / 波形 / 确认"胶囊,参考 iMessage/微信语音
    /// 消息录制条:左边取消(丢弃录音、不转写、不发送),中间波形随音量起伏,
    /// 右边确认(等同原先"录音中再点一次麦克风"——停止并走已有的自动发送流程)。
    private var recordingBar: some View {
        HStack(spacing: 12) {
            cancelRecordingButton
            RecordingWaveform(level: speech.audioLevel)
                .frame(maxWidth: .infinity)
            confirmRecordingButton
        }
        .frame(height: 40)
    }

    private var cancelRecordingButton: some View {
        Button {
            speech.cancel()
            text = typedPrefix
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("取消录音")
    }

    private var confirmRecordingButton: some View {
        Button {
            speech.stop()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("完成录音")
    }

    /// 录音条中间的波形:固定数量竖条,用系统 Shape(Capsule)组合而成——不是
    /// Canvas 自绘。每根条按时间连续起伏(TimelineView(.animation),和
    /// BreathingMicIcon/ShimmerText 同一个写法),相邻条相位错开一点,视觉上像
    /// 一条波浪从左往右流动,而不是一排各自独立跳变的柱子;起伏幅度按 level
    /// (SpeechInput.audioLevel,0...1)放大——声音越大摆动越明显,安静时也保留
    /// 一点点小幅起伏(呼吸感),不会瘫平成死气沉沉的静止条。遵守"减弱动态
    /// 效果":开启时退化成等高静止的条,不逐帧重绘。
    private struct RecordingWaveform: View {
        let level: Float

        private static let barCount = 24
        private static let barWidth: CGFloat = 3
        private static let barSpacing: CGFloat = 3
        private static let minBarHeight: CGFloat = 5
        private static let maxBarHeight: CGFloat = 34
        /// 相邻条的相位间隔,决定"波浪流动"的疏密。
        private static let phaseStep: Double = 0.34
        /// 起伏一个完整周期的时长(秒)。
        private static let period: Double = 0.9
        /// 静音时仍保留的最小摆动幅度(0...1),避免完全静止。
        private static let idleAmplitude: Double = 0.18

        var body: some View {
            if DesignMetrics.reduceMotionEnabled {
                staticBars
            } else {
                TimelineView(.animation) { context in
                    bars(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }

        private var staticBars: some View {
            HStack(spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { _ in
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: Self.barWidth, height: Self.minBarHeight)
                }
            }
        }

        private func bars(time: Double) -> some View {
            let amplitude = Self.idleAmplitude + (1 - Self.idleAmplitude) * Double(level)
            return HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let phase = Double(index) * Self.phaseStep
                    let wave = (sin(time * 2 * .pi / Self.period - phase) + 1) / 2
                    let height = Self.minBarHeight
                        + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(amplitude * wave)
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: Self.barWidth, height: height)
                }
            }
        }
    }

    /// 录音态由 inputBarRow 整条换成 recordingBar,不会走到这里——这个开关只管
    /// "没在录音"时麦克风 ↔ 发送按钮的切换。busy 期间发送按钮变成取消,必须强制
    /// 显示——不然请求一发出、输入框被清空,hasComposedContent 又变 false,取消
    /// 按钮会被这条规则顶掉、换回(此时禁用的)麦克风按钮,用户就没有取消入口了。
    private var showsInlineMic: Bool {
        !busy && !hasComposedContent
    }

    /// 云端语音识别引擎:录音已停止、转写请求还没回来,替掉麦克风按钮的位置。
    private var speechProcessingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .accessibilityLabel("识别中")
    }

    private var inlineMicButton: some View {
        Button {
            typedPrefix = text
            speech.toggle()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .disabled(busy)
        .accessibilityLabel("语音输入")
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
                .font(.system(size: busy ? 15 : 17, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .glassProminentButton()
        .buttonBorderShape(.circle)
        // .glassProminentButton()/.borderedProminent 自带一圈系统内容内边距+HIG 最小
        // 触控尺寸,单靠 label 内部 36×36 的 frame 圈不住,发出键因此比左边 +/麦克风
        // (.buttonStyle(.plain),没有这层自动内边距)看起来大一圈——外面叠加 .frame
        // 对 iOS 26 Liquid Glass 圆形按钮不生效(实测无变化,系统内部按自己的最小触控
        // 尺寸布局,不理会下游 frame 收窄),只能靠 .controlSize 调系统档位。
        .controlSize(.mini)
        .tint(busy ? Color.secondary : Color.accentColor)
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

    /// excluding 为 nil 时不排除任何消息(询问卡回传选择那条路径没有用户气泡可排除)。
    private func recentHistory(in thread: AgentThread, excluding: AgentMessage?) -> [(role: String, content: String)] {
        let threadUUID = thread.uuid
        let excludeUUID = excluding?.uuid
        let all = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> { $0.threadUUID == threadUUID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return all.filter { $0.uuid != excludeUUID }.suffix(16)
            .map { (role: $0.roleRaw, content: $0.content) }
    }

    @discardableResult
    private func appendAssistant(
        thread: AgentThread, kind: AgentMessageKind, content: String,
        relatedTitles: [String] = [], askSnapshotData: Data? = nil,
        taskSnapshotData: Data? = nil, resultMemoryUUID: UUID? = nil
    ) -> AgentMessage {
        let message = AgentMessage(threadUUID: thread.uuid, role: .assistant, kind: kind,
                                   content: content, relatedTitles: relatedTitles,
                                   askSnapshotData: askSnapshotData, taskSnapshotData: taskSnapshotData,
                                   resultMemoryUUID: resultMemoryUUID)
        context.insert(message)
        thread.updatedAt = Date()
        try? context.save()
        return message
    }

    /// 单条新建/修改:AI 一解析完就追加一条待确认气泡(内联卡片 + Cancel/Confirm),
    /// 不再自动弹表单——点卡片本身才跳到 TaskEditView(见 handleTaskProposalTap)。
    private func appendTaskProposal(thread: AgentThread, existingUUID: UUID?, parsed: ParsedTask) {
        let snapshot = AgentTaskSnapshot(existingUUID: existingUUID, parsed: parsed)
        appendAssistant(thread: thread, kind: .taskProposal,
                        content: existingUUID == nil ? "新建" : "修改",
                        taskSnapshotData: try? JSONEncoder().encode(snapshot))
    }

    /// 确认(直接点 Confirm,或点卡片进表单改完保存)后的最终态,只读卡片。
    private func appendTaskResult(thread: AgentThread, existingUUID: UUID?, parsed: ParsedTask) {
        let snapshot = AgentTaskSnapshot(existingUUID: existingUUID, parsed: parsed)
        appendAssistant(thread: thread, kind: .taskResult,
                        content: existingUUID == nil ? "已新建" : "已修改",
                        taskSnapshotData: try? JSONEncoder().encode(snapshot))
    }

    /// 按 taskSnapshotData 里的 existingUUID 查出对应的既有事项(修改时用于
    /// 预填/落库定位;新建时恒为 nil)。
    private func existingTask(for uuid: UUID?) -> TaskItem? {
        guard let uuid else { return nil }
        return try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.uuid == uuid })).first
    }

    /// taskProposal 气泡的"确认新建/确认修改"按钮:原样按 AI 解析出的字段保存,
    /// 不弹表单。
    private func handleTaskProposalConfirm(_ message: AgentMessage) {
        guard let thread = activeThread,
              let data = message.taskSnapshotData,
              let snapshot = try? JSONDecoder().decode(AgentTaskSnapshot.self, from: data)
        else { return }
        saveTask(existingTask(for: snapshot.existingUUID), snapshot.parsed)
        appendTaskResult(thread: thread, existingUUID: snapshot.existingUUID, parsed: snapshot.parsed)
    }

    private func handleTaskProposalCancel(_ message: AgentMessage) {
        guard let thread = activeThread else { return }
        appendAssistant(thread: thread, kind: .text, content: "已取消这次操作。")
    }

    /// 点卡片本身:AI 解析偶尔会错,跳到现有的 TaskEditView 表单微调后再保存
    /// (复用 formTarget 这套既有 sheet 机制,只是触发时机从"一解析完自动弹"
    /// 改成"用户主动点卡片")。
    private func handleTaskProposalTap(_ message: AgentMessage) {
        guard let data = message.taskSnapshotData,
              let snapshot = try? JSONDecoder().decode(AgentTaskSnapshot.self, from: data)
        else { return }
        formTarget = FormTarget(existing: existingTask(for: snapshot.existingUUID), parsed: snapshot.parsed)
    }

    /// 询问卡答完:原地把这条消息变成只读记录卡(问题 + 答案),再把选择静默
    /// 回传给 AI 出最终 actions——不冒一条用户气泡,记录卡本身就是"用户答了什么"
    /// 的凭据(content 同步写成可读文本,recentHistory 因此天然带上答案)。
    private func handleAskSubmit(_ message: AgentMessage, answers: [[String]]) {
        guard let thread = activeThread,
              let data = message.askSnapshotData,
              var snapshot = try? JSONDecoder().decode(AgentAskSnapshot.self, from: data)
        else { return }
        snapshot.answers = answers
        message.kindRaw = AgentMessageKind.askResult.rawValue
        message.askSnapshotData = try? JSONEncoder().encode(snapshot)
        message.content = snapshot.transcript
        thread.updatedAt = Date()
        try? context.save()
        send(overrideText: "(用户已回答上面的问题)\n\(snapshot.transcript)", hidesUserBubble: true)
    }

    private func handleAskCancel(_ message: AgentMessage) {
        guard let thread = activeThread else { return }
        appendAssistant(thread: thread, kind: .text, content: "已取消这次提问。")
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

    /// "收藏这条"按钮:AI 主动建议、用户确认后才真正落库,展示形态和 memorize
    /// 分支(route() 里)一致的记忆结果卡片。
    private func handleMemorizeSuggestion(_ message: AgentMessage) {
        guard let thread = activeThread else { return }
        let item = MemoryPipeline.saveText(message.content, context: context)
        appendAssistant(thread: thread, kind: .memoryResult, content: "已收藏",
                        resultMemoryUUID: item?.uuid)
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

    // MARK: - 长按气泡:复制/引用/修改

    private func copyMessageContent(_ message: AgentMessage) {
        #if os(iOS)
        UIPasteboard.general.string = message.content
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
        Haptics.success()
    }

    private func quoteMessage(_ message: AgentMessage) {
        quotedMessage = message
        isInputFocused = true
    }

    /// 只是打开确认弹窗,真正的截断删除发生在用户点确认之后(见 performEdit)。
    private func requestEdit(_ message: AgentMessage) {
        pendingEdit = message
    }

    /// 删除这条消息及其后(按 createdAt)所有历史(含 AI 回复),把原文回填输入框。
    private func performEdit(_ message: AgentMessage) {
        let threadUUID = message.threadUUID
        let cutoff = message.createdAt
        let toDelete = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> {
                $0.threadUUID == threadUUID && $0.createdAt >= cutoff
            }))) ?? []
        for item in toDelete { context.delete(item) }
        try? context.save()
        if let quoted = quotedMessage, toDelete.contains(where: { $0.uuid == quoted.uuid }) {
            quotedMessage = nil
        }
        text = message.content
        isInputFocused = true
    }

    // MARK: - 提交

    /// hidesUserBubble:这次提交不代表用户"说了一句话",不插用户气泡也不动
    /// thread 标题(询问卡答完后回传选择就走这条路——对话里留下的是那张记录卡,
    /// 再冒一条内容重复的蓝气泡反而啰嗦)。其余流程(busy/取消/思考提示/错误)
    /// 与正常发送完全一致。
    private func send(overrideText: String? = nil, hidesUserBubble: Bool = false) {
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
        let quoted = quotedMessage
        quotedMessage = nil
        text = ""

        var userMessage: AgentMessage?
        if !hidesUserBubble {
            let message = AgentMessage(
                threadUUID: thread.uuid, role: .user, content: trimmed,
                attachmentMemoryUUIDs: attachments.compactMap(\.memoryUUID),
                quotedContent: quoted?.content)
            context.insert(message)
            userMessage = message
            }
        // 首轮对话:先用截断兜底,立刻有个标题;拿到 AI 回复后再尝试换成真正的总结标题
        // (刚打开时导航栏显示"AI 助手",这里是它第一次变成 thread 标题的地方)。
        let isFirstMessage = !hidesUserBubble && thread.title.isEmpty
        if isFirstMessage {
            let seed = trimmed.isEmpty ? (attachments.first?.displayName ?? "") : trimmed
            thread.title = MemorySearch.truncate(seed, limit: 20)
        }
        thread.updatedAt = Date()
        try? context.save()

        let history = recentHistory(in: thread, excluding: userMessage)
        var outgoing = trimmed
        if let quoted {
            outgoing = "引用消息:「\(quoted.content)」\n\n" + outgoing
        }
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
                    appendTaskProposal(thread: thread, existingUUID: existing?.uuid, parsed: parsed)
                case .updated(let task, let parsed):
                    appendTaskResult(thread: thread, existingUUID: task.uuid, parsed: parsed)
                case .confirm(let lines):
                    appendAssistant(thread: thread, kind: .confirm, content: lines.joined(separator: "\n"))
                case .ask(let questions):
                    let snapshot = AgentAskSnapshot(questions: questions)
                    appendAssistant(
                        thread: thread, kind: .ask,
                        content: questions.map(\.question).joined(separator: "\n"),
                        askSnapshotData: try? JSONEncoder().encode(snapshot))
                case .answer(let text, let related):
                    appendAssistant(thread: thread, kind: .answer, content: text, relatedTitles: related)
                case .suggestMemorize(let text):
                    appendAssistant(thread: thread, kind: .memorizeSuggestion, content: text)
                case .memorized(let uuid):
                    appendAssistant(thread: thread, kind: .memoryResult, content: "已收藏",
                                    resultMemoryUUID: uuid)
                case .autoMemorized(let uuid):
                    appendAssistant(thread: thread, kind: .memoryResult, content: "已自动记录",
                                    resultMemoryUUID: uuid)
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
        case .routeToForm(_, let parsed): return "新建了事项:\(parsed.title)"
        case .updated(_, let parsed): return "修改了事项:\(parsed.title)"
        case .confirm(let lines): return lines.joined(separator: ";")
        case .ask(let questions): return questions.first?.question ?? ""
        case .answer(let text, _): return text
        case .suggestMemorize(let text): return text
        case .memorized: return "已收藏一条记忆"
        case .autoMemorized: return "自动记录了一条信息"
        }
    }

    #if DEBUG
    /// 截图验证用:把对话列表填到能看出滚动和高亮的量(只在几乎为空时插)。
    private func seedDemoThreads() {
        guard threads.count < 3 else { return }
        let titles = [
            "明天下午的会议安排", "整理这周的待办", "帮我记一下 wifi 密码",
            "把周报相关的都完成", "台风对航班的影响", "下周体检提醒",
            "把过期的清理掉", "买菜清单",
        ]
        for (index, title) in titles.enumerated() {
            let thread = AgentThread()
            thread.title = title
            // 倒序排列稳定一点:越靠前的越"新"。
            thread.updatedAt = Date().addingTimeInterval(-Double(index) * 3600)
            context.insert(thread)
        }
        try? context.save()
    }

    /// 截图验证用:模拟确认清单 / 反问 / 回答三种回应态。
    private func seedDemoMessagesIfNeeded() {
        guard let thread = activeThread else { return }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-confirm") {
            appendAssistant(thread: thread, kind: .confirm,
                            content: "新建:开周会(明天 15:00 · 60 分钟)\n完成:给妈妈回电话\n删除:取快递")
        }
        // 询问卡:三道题(单选 + 多选各有),覆盖翻页器、推荐角标、其他输入框。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-ask") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "提醒我交材料"))
            appendAssistant(
                thread: thread, kind: .ask,
                content: Self.demoAskSnapshot.questions.map(\.question).joined(separator: "\n"),
                askSnapshotData: try? JSONEncoder().encode(Self.demoAskSnapshot))
        }
        // 答完之后的记录卡。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-ask-result") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "提醒我交材料"))
            var answered = Self.demoAskSnapshot
            answered.answers = [["明天 09:00"], ["30 分钟"], ["身份证", "复印件"]]
            appendAssistant(thread: thread, kind: .askResult, content: answered.transcript,
                            askSnapshotData: try? JSONEncoder().encode(answered))
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
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-proposal") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "明天下午3点开会,60分钟"))
            appendTaskProposal(thread: thread, existingUUID: nil, parsed: Self.demoParsedTask)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-result") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "明天下午3点开会,60分钟"))
            appendTaskResult(thread: thread, existingUUID: nil, parsed: Self.demoParsedTask)
        }
        // 修改结果卡片(带撤销按钮),和上面创建结果卡片(不带撤销按钮)对照截图用。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-result-updated") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "开会挪到下午4点"))
            appendTaskResult(thread: thread, existingUUID: UUID(), parsed: Self.demoParsedTask)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-memory-result") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "记住wifi密码是8888"))
            let item = MemoryPipeline.saveText("wifi密码是8888", context: context)
            appendAssistant(thread: thread, kind: .memoryResult, content: "已收藏",
                            resultMemoryUUID: item?.uuid)
        }
        // 打字机动画:插入一条 createdAt 晚于 typingBaseline 的 .text 回复,
        // 触发逐字显示 + 逐字振动(和加载已有历史消息时的"整段直接显示"对照)。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-text-reply") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "帮我看看今天忙不忙"))
            appendAssistant(thread: thread, kind: .text,
                            content: "今天你只有一件事——下午3点开会,其余时间都空着,可以安排点别的。")
        }
        // 用户气泡带引用摘要(quote.bubble 图标 + 单行截断),对照气泡渲染用。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-quoted") {
            let quoted = AgentMessage(threadUUID: thread.uuid, role: .assistant,
                                      content: "你收藏的 wifi 密码是 8888。")
            context.insert(quoted)
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "谢谢",
                                        quotedContent: quoted.content))
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
            // 抽屉归外壳管,这里只负责把数据塞出来;要连带推开抽屉截图的话
            // 配合 --demo-sidebar 一起传(见 AppShellView.applyDemoArguments)。
        }
    }

    private static var demoParsedTask: ParsedTask {
        ParsedTask(title: "开会", remindAt: Date().addingTimeInterval(3600),
                   allDay: false, durationMinutes: 60, repeatType: .none,
                   repeatDays: [], repeatTimes: [])
    }

    private static var demoAskSnapshot: AgentAskSnapshot {
        AgentAskSnapshot(questions: [
            AskQuestion(header: "提醒时间", question: "什么时候提醒你交材料?", options: [
                AskOption(label: "明天 09:00", description: "上班第一件事就办掉", recommended: true),
                AskOption(label: "今晚 20:00", description: "今天之内交完,明天不再惦记"),
                AskOption(label: "后天 14:00", description: "留出两天准备时间"),
            ]),
            AskQuestion(header: "时长", question: "这件事大概要占多久?", options: [
                AskOption(label: "30 分钟", description: "按你以前交材料的耗时估的", recommended: true),
                AskOption(label: "1 小时", description: "需要现场排队的话留够时间"),
                AskOption(label: "不用记时长", description: "只要一个到点提醒"),
            ]),
            AskQuestion(header: "材料", question: "要带哪些材料?", multiSelect: true, options: [
                AskOption(label: "身份证", description: "大多数窗口都要", recommended: true),
                AskOption(label: "复印件", description: "一并带上省得现场复印"),
                AskOption(label: "照片", description: "一寸免冠照"),
            ]),
        ])
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
    let onTaskProposalConfirm: (AgentMessage) -> Void
    let onTaskProposalCancel: (AgentMessage) -> Void
    let onTaskProposalTap: (AgentMessage) -> Void
    let onAskSubmit: (AgentMessage, [[String]]) -> Void
    let onAskCancel: (AgentMessage) -> Void
    let onExamplePrompt: (String) -> Void
    let onCopy: (AgentMessage) -> Void
    let onQuote: (AgentMessage) -> Void
    let onEdit: (AgentMessage) -> Void

    @Query private var messages: [AgentMessage]
    /// 这个 thread 视图这次打开的时间点;晚于它 createdAt 的 .text 回复才播打字机
    /// 动画("这次会话里刚收到的新回复"),早于它的历史消息一律整段直接显示。
    /// .id(thread.uuid) 强制换 thread 时这个 struct 连带 @State 一起重建,
    /// 天然按 thread 各自归零,不需要额外重置逻辑。
    @State private var typingBaseline = Date()

    init(thread: AgentThread, onConfirmAction: @escaping (AgentMessage, Bool) -> Void,
         onUndo: @escaping () -> Void, onMemorizeSuggestion: @escaping (AgentMessage) -> Void,
         onTaskProposalConfirm: @escaping (AgentMessage) -> Void,
         onTaskProposalCancel: @escaping (AgentMessage) -> Void,
         onTaskProposalTap: @escaping (AgentMessage) -> Void,
         onAskSubmit: @escaping (AgentMessage, [[String]]) -> Void,
         onAskCancel: @escaping (AgentMessage) -> Void,
         onExamplePrompt: @escaping (String) -> Void,
         onCopy: @escaping (AgentMessage) -> Void,
         onQuote: @escaping (AgentMessage) -> Void,
         onEdit: @escaping (AgentMessage) -> Void) {
        self.thread = thread
        self.onConfirmAction = onConfirmAction
        self.onUndo = onUndo
        self.onMemorizeSuggestion = onMemorizeSuggestion
        self.onTaskProposalConfirm = onTaskProposalConfirm
        self.onTaskProposalCancel = onTaskProposalCancel
        self.onTaskProposalTap = onTaskProposalTap
        self.onAskSubmit = onAskSubmit
        self.onAskCancel = onAskCancel
        self.onExamplePrompt = onExamplePrompt
        self.onCopy = onCopy
        self.onQuote = onQuote
        self.onEdit = onEdit
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
                            onMemorizeSuggestion: { onMemorizeSuggestion(message) },
                            onTaskProposalConfirm: { onTaskProposalConfirm(message) },
                            onTaskProposalCancel: { onTaskProposalCancel(message) },
                            onTaskProposalTap: { onTaskProposalTap(message) },
                            onAskSubmit: { onAskSubmit(message, $0) },
                            onAskCancel: { onAskCancel(message) },
                            onCopy: { onCopy(message) },
                            onQuote: { onQuote(message) },
                            onEdit: { onEdit(message) },
                            typingBaseline: typingBaseline)
                        .id(message.uuid)
                    }
                }
                .padding()
                .animation(.lodoAware(.snappy), value: messages.count)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.lodoAware(.snappy)) { proxy.scrollTo(last.uuid, anchor: .bottom) }
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
