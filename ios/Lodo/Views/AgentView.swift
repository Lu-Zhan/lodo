import SwiftUI
import SwiftData
import PhotosUI
import LodoCore
#if os(iOS)
import UIKit
#endif

/// AI 对话页(抽屉里的平级页面之一):**单一持续对话**——一条永不结束的时间线,
/// 没有"新建对话"这回事,每轮请求带上最近几轮历史(更早的压成摘要,见
/// `AgentConversationSummary`);右下角语音、左侧 + 号传照片/文件。
/// 单条新建/修改叠一个 TaskEditView 在本页上面("表单即确认"这个体验保留),
/// 保存后往对话末尾追加一条结果消息,不关掉聊天页。
/// 抽屉本身归外壳(AppShellView/AppSidebarView),这里只管聊天区。
struct AgentView: View {
    @Environment(\.lodoAccent) private var lodoAccent
    /// 非 nil 时把文本预填进输入框(深链/Siri 交接/小组件"+"),消费后置 nil。
    @Binding var pendingPrefill: String?
    /// 解析并路由输入文本 + 最近对话历史;onThought 在 ReAct 循环中间步骤时被调用
    /// (如"正在查记忆…"),驱动 thinkingText 那条轻量提示。返回本页要展示的回应形态。
    /// onStream 收到的是"到目前为止的全文"(不是增量),直接赋给预览气泡即可;
    /// 收到空串表示流式失败要回退,得把已经显示的半句清掉。
    let submit: (
        String, [(role: String, content: String)], @escaping (String) -> Void,
        @escaping (String) -> Void, @escaping (String) -> Void
    ) async throws -> AgentReply
    /// 用户确认执行批量操作(操作暂存在 AgentHostView)。
    let onConfirm: () -> Void
    /// 撤销上一批已执行的操作(AgentHostView.performUndo),返回要展示给用户的
    /// 回应文案;"已完成执行"气泡上的撤销按钮直接调这个,不用再走一遍文字指令。
    let onUndo: () -> AgentReply
    /// 单条新建/修改保存,existing 为 nil 表示新建。
    let saveTask: (TaskItem?, ParsedTask) -> Void
    /// 新建结果卡片上那一下点击。传当前有效事项的 uuid = 删掉它并返回 nil;
    /// 传 nil = 按快照重新建一条并返回新 uuid。
    let toggleCreatedTask: (UUID?, ParsedTask) -> UUID?
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    /// ReAct 循环中间步骤的轻量提示(如"正在查记忆…");不落库,循环一结束就清空。
    @State private var thinkingText: String?
    /// 流式回复的临时预览,渲染在消息列表末尾;不落库,请求一结束就清空
    /// (真正那条 .answer 消息随即落库,长相一样,不会跳布局)。
    @State private var streamingAnswer: String?

    @State private var text = ""
    @State private var busy = false
    /// 发送中的请求;busy 时发送按钮变成取消,点了就 cancel 这个 Task。
    @State private var sendTask: Task<Void, Never>?
    /// 推理模型吐出的思考过程的尾巴,喂给"思考中…"那行;每轮请求结束清空。
    @State private var reasoningTail = ""

    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 打开页面默认唤起键盘,方便直接打字;语音改成手动点麦克风图标触发。
    @FocusState private var isInputFocused: Bool
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""
    /// 对话最后一条是还没答的询问卡。这时整条输入区收起来——问题就摆在
    /// 那儿等着选,底下再留个输入框是两个并行的入口,容易让人以为要打字回答;
    /// 想自由回答的话询问卡自己带"其他"输入,不想答就点卡片上的取消(取消会追加
    /// 一条文本消息,最后一条不再是询问卡,输入区随即回来)。
    @State private var hasPendingAsk = false
    /// 长按气泡选了"引用"后待发送的那条消息;输入框上方的引用预览行据此渲染,
    /// 发送时会把它的文本折进 outgoing(不写回气泡展示用的 content)。
    @State private var quotedMessage: AgentMessage?
    /// 长按气泡选了"修改"后待确认的目标;只是打开确认弹窗,真正的截断删除
    /// 发生在用户在 confirmationDialog 里点确认之后。
    @State private var pendingEdit: AgentMessage?

    /// 消息列表一次取多少条。对话是单一持续时间线、永不结束,全表灌进 @Query
    /// 会把整条历史实例化在启动路径上(AI 页还是冷启动的落地页)。倒序取这么多
    /// 条,顶上留一颗「载入更早的对话」把它加一页。
    @State private var historyWindow = AgentView.historyPageSize
    /// 后台压缩正在跑;防重入(连发两条消息时不重复压同一批)。
    @State private var isCompacting = false
    static let historyPageSize = 200
    /// 一次最多压缩多少条。够覆盖正常节奏下攒出来的量,又不至于让长期离线后的
    /// 第一次压缩把几千条一股脑塞进 prompt。
    static let maxCompressBatch = 200

    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false
    @State private var showMemoryPicker = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// 点了输入卡片里的某张缩略图:非 nil 时全屏打开大图查看,值是起始那张的 id。
    @State private var viewingImage: ImageViewerTarget?
    @State private var formTarget: FormTarget?
    /// 小彩蛋:输入框内容恰好是 "0707"(气球生日祝福)或 "0829"(结婚一周年,
    /// 爱心)时弹一个全屏动画,见下面的 .onChange(of: text) 和 EasterEggView。
    @State private var showEasterEgg = false
    @State private var easterEggOccasion: EasterEggView.Occasion = .birthday

    /// @State 属性都是 private,合成的 memberwise init 会跟着降级成 private、
    /// 别的文件用不了,所以显式写一个。
    init(pendingPrefill: Binding<String?>,
         submit: @escaping (
            String, [(role: String, content: String)], @escaping (String) -> Void,
            @escaping (String) -> Void, @escaping (String) -> Void
         ) async throws -> AgentReply,
         onConfirm: @escaping () -> Void,
         onUndo: @escaping () -> AgentReply,
         saveTask: @escaping (TaskItem?, ParsedTask) -> Void,
         toggleCreatedTask: @escaping (UUID?, ParsedTask) -> UUID?) {
        self._pendingPrefill = pendingPrefill
        self.submit = submit
        self.onConfirm = onConfirm
        self.onUndo = onUndo
        self.saveTask = saveTask
        self.toggleCreatedTask = toggleCreatedTask
    }

    /// 消费外壳递进来的预填文本。空串表示"只是把页面切过来",不覆盖用户已经
    /// 打了一半的内容(和原来 prefill 为空时不动 text 的行为一致)。
    private func consumePrefill() {
        guard let request = pendingPrefill else { return }
        pendingPrefill = nil
        if !request.isEmpty { text = request }
        isInputFocused = true
    }

    /// 标题下面那行小字的前半截:当前服务商。
    ///
    /// 这儿曾经还带思考强度——那是个静态设置项(设置页有 Picker),摆在对话页
    /// 最显眼的位置每次都一样、没有信息量,现在让位给 token 用量与速度
    /// (`AgentTitleView` 自己读 `AIUsageMonitor`)。
    private var aiModeSummary: String { AppSettings.aiProvider }

    /// 后半截:联网搜索是否已配置。有 token 指标可报时被指标顶掉(见
    /// `AgentTitleView`)——导航栏这行放不下两截都留。
    private var aiCapabilitySummary: String? {
        WebSearchClient.isConfigured ? "联网搜索" : nil
    }

    var body: some View {
        // 右侧栏:对话里产出的页面(规划/调整后的行程)在旁边展示,见 AgentInspector.swift。
        AgentInspectorHost {
            chatStack
        }
        .onChange(of: pendingPrefill) { _, _ in consumePrefill() }
    }

    private var chatStack: some View {
        NavigationStack {
            chatColumn
            // 这里曾经 .ignoresSafeArea(.container, edges: .bottom),让输入栏贴到
            // 屏幕物理底边、不给 home indicator 留白边。现在整页底色由 AppShellView
            // 统一铺到物理边缘了,那条"死白边"本来就不存在;继续贴底反而有害:抽屉
            // 推开时页面被裁成 44pt 圆角,输入栏自己 26pt 的玻璃圆角正好落进那个圆角
            // 里,两道弧线套在一起。让输入栏收回安全区之上即可(消息仍然从它背后滚
            // 过去,底部那截不是死区)。
            .navigationTitle("AI 助手")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // 自定义 principal:标题恒为「AI 助手」(单一持续对话,没有
                // 每段对话各自的标题了);标题下加一行
                // 当前 AI 模式(服务商/思考强度/联网搜索),不然用户在对话里完全
                // 看不出现在到底是哪个服务商、思考开没开、能不能联网搜索——
                // 这些都要跳回设置页才看得到。
                // principal 项恒定渲染(只淡出内容),抽屉展开/拖拽时导航栏高度
                // 才不会跟着两行标题的消失/出现联动跳变,chatColumn 紧贴在导航栏
                // 下方布局,导航栏一变高聊天区就会跟着窜一下——这是纯文字 VStack,
                // 没有 Liquid Glass 背景,可以放心用 opacity(☰ 那颗不行,它带
                // 系统画的 Liquid Glass 底,见 sidebarToolbarButton 的注释)。
                // 标题拆成子视图:判据要从它自己所在位置读 sidebarChrome——右栏拉开时
                // 容器会在这一层往下覆盖一份"藏起 chrome"的值,AgentView 本身读不到。
                ToolbarItem(placement: .principal) {
                    AgentTitleView(title: "AI 助手", mode: aiModeSummary,
                                   capability: aiCapabilitySummary)
                }
            }
            .sidebarToolbarButton()
            .agentInspectorToolbarButton()
            .sheet(item: $formTarget) { target in
                TaskEditView(existing: target.existing, parsed: target.parsed,
                             attachment: target.existing?.attachment) { savedParsed in
                    saveTask(target.existing, savedParsed)
                    appendTaskResult(existingUUID: target.existing?.uuid, parsed: savedParsed)
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
            // PhotosPicker 不能直接放进 Menu:菜单一收起,挂在菜单项上的相册
            // 弹窗跟着一起没了,点「照片」什么都不发生。菜单里只放按钮,
            // 相册弹窗挂在页面上。
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection,
                          maxSelectionCount: max(1, remainingPhotoSlots),
                          selectionBehavior: .ordered, matching: .images)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                // PhotosPicker 的选择是全量的,读完就清空,下次再点是"再加几张"。
                // 按选择顺序逐张读,缩略图顺序和用户点选的顺序一致。
                photoSelection = []
                Task {
                    for item in items {
                        guard remainingPhotoSlots > 0,
                              let data = try? await item.loadTransferable(type: Data.self)
                        else { continue }
                        handlePickedImage(data)
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $viewingImage) { target in
                AgentImageViewer(images: pendingImages, initialID: target.id)
            }
            #else
            .sheet(item: $viewingImage) { target in
                AgentImageViewer(images: pendingImages, initialID: target.id)
            }
            #endif
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
                isInputFocused = true
                consumePrefill()
                #if DEBUG
                seedDemoMessagesIfNeeded()
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-hascontent") {
                    text = "明天3点开会"
                }
                // 连通性验证用:启动即真发一次请求,看当前服务商/模型调不调得通
                // (换模型/换服务商之后拿它探一下,不用手打字)。**会真的产生一次
                // 网络请求和一条对话记录**,只在 DEBUG 且显式带这个参数时才跑。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-live") {
                    send(overrideText: "只回复两个字:可用")
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
                // 截图验证用:推开抽屉看侧栏那步由 AppShellView 的
                // --demo-agent-sidebar/--demo-sidebar 负责,这里只把键盘收掉,
                // 免得抽屉被键盘挤掉一截。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-sidebar") {
                    isInputFocused = false
                }
                // 截图验证用:模拟长按气泡选了"引用"——simctl 没法长按弹
                // contextMenu,直接把状态摆出来看输入框上方的预览行(超长文本
                // 单行省略号截断)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-quote-preview") {
                    let quoted = AgentMessage(
                        role: .assistant,
                        content: "你收藏的 wifi 密码是 8888,这是一段特意写得很长很长用来测试单行省略号截断效果的引用预览文本。")
                    context.insert(quoted)
                    try? context.save()
                    quotedMessage = quoted
                }
                // 截图验证用:simctl 没法操作相册,直接塞几张合成图当作选好的照片,
                // 看输入卡片里的缩略图行;加 --demo-agent-photo-viewer 再打开大图查看页。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-photos") {
                    seedDemoPhotos()
                }
                // 截图验证用:不发网络,自己逐片喂 streamingAnswer,截流式中态。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-stream") {
                    busy = true
                    Task { @MainActor in
                        let full = "杭州明天多云转小雨,白天 24 度、夜里 19 度,傍晚那阵雨下得急。"
                        var shown = ""
                        for character in full {
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            shown.append(character)
                            streamingAnswer = shown
                        }
                    }
                }
                // 截图验证用:不走网络,直接往用量观察点里摆一轮完成态的数字,
                // 看标题第二行那截「↑… ↓… · NN tok/s」的排版和截断。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-usage") {
                    AIUsageMonitor.shared.seed(
                        AIUsage(inputTokens: 1120, outputTokens: 320, isEstimated: false,
                                generatingSeconds: 10, requests: 1))
                }
                // 截图验证用:模拟长按气泡选了"修改"——直接弹出截断确认弹窗
                // (simctl 没法长按+点菜单项)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-edit-confirm") {
                    let target = AgentMessage(role: .user, content: "明天下午3点开会")
                    context.insert(target)
                    context.insert(AgentMessage(role: .assistant, kind: .text,
                                                content: "好的,已经帮你记下明天下午3点开会。"))
                    try? context.save()
                    pendingEdit = target
                }
                #endif
            }
        }
    }

    // MARK: - 聊天区

    /// 消息列表 + 输入栏这一整块。
    private var chatColumn: some View {
        // 输入栏这坨挂在 ScrollView 的 safeAreaInset(而不是跟消息列表
        // 平铺在同一个 VStack 里),消息才会真的滚到它背后。参考系统
        // Messages/语音备忘录的输入栏:这块区域本身不铺任何背景色——
        // +/文本框/麦克风三个控件各自是独立的 Liquid Glass 胶囊(见
        // inputBar),控件之间、控件下方一路到屏幕真实底边都是真透明,
        // 露出的是聊天内容本身,不是另一块单独的磨砂色块。
        AgentMessageListView(
            historyWindow: historyWindow,
            streamingAnswer: streamingAnswer,
            onLoadEarlier: { historyWindow += Self.historyPageSize },
            onConfirmAction: handleConfirmAction,
            onUndo: handleUndo,
            onMemorizeSuggestion: handleMemorizeSuggestion,
            onCancelMemoryResult: handleCancelMemoryResult,
            onToggleCreatedTask: handleToggleCreatedTask,
            onTaskProposalConfirm: handleTaskProposalConfirm,
            onTaskProposalCancel: handleTaskProposalCancel,
            onTaskProposalTap: handleTaskProposalTap,
            onAskSubmit: handleAskSubmit,
            onAskCancel: handleAskCancel,
            onExamplePrompt: { send(overrideText: $0) },
            onCopy: copyMessageContent,
            onQuote: quoteMessage,
            onEdit: requestEdit,
            onPendingAskChange: { hasPendingAsk = $0 })
            // 换一次窗口大小就要重建 @Query(SwiftData 动态 descriptor 的标准
            // 写法),正是原来切 thread 时 .id(thread.uuid) 那一套。
            .id(historyWindow)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    thinkingRow
                    if !hasPendingAsk {
                        attachmentChipsRow
                        quotedPreviewRow
                        if let error = errorText ?? speech.errorText {
                            Text(error).font(.subheadline).foregroundStyle(LodoColor.critical)
                                .padding(.horizontal)
                        }
                        inputBar
                    }
                }
                .animation(.lodoAware(.snappy(duration: 0.2)), value: hasPendingAsk)
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

    /// 多附件横向胶囊行(文件/从记忆库选的条目可以并存),每个单独可移除。
    /// 相册选的照片不在这里,是输入卡片里带缩略图的那一行(photoPreviewRow)。
    @ViewBuilder
    private var attachmentChipsRow: some View {
        if pendingAttachments.contains(where: { $0.imageData == nil }) {
            HorizontalChipRow {
                ForEach(pendingAttachments.filter { $0.imageData == nil }) { attachment in
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
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    quotedMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .pressable()
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
                .font(.subheadline)
                .lineLimit(1)
            Button {
                removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .pressable()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DesignMetrics.chipRadius, style: .continuous))
    }

    /// 输入栏悬浮在内容上方(四周留白,不贴屏幕物理边缘),**一整行**:
    /// 左边 + 号是一颗独立的 Liquid Glass 圆钮,右边一路到底是玻璃输入胶囊,
    /// 麦克风/发送**嵌在胶囊里**靠右端。没在打字时是麦克风(点了开始录音);
    /// 一旦有内容待发送,同一个槽位换成强调色发送按钮——两态**同尺寸同圆心**
    /// (都是 composerInlineControlSize 见方),换按钮时胶囊和文本纹丝不动。
    /// 发送/停止那颗是实心强调色圆,麦克风是纯图标(它已经落在胶囊的玻璃底上,
    /// 不用再套一层玻璃——玻璃也采样不到玻璃)。
    ///
    /// 原来是"一整块合并的磨砂卡片、里面竖直分两行(文本框在上、控件行在下)",
    /// 高度 86pt;现在是一行两块形状(+ 号、胶囊),只剩 36pt。拆开之后 + 号和
    /// 输入胶囊是**两块挨着的玻璃**,所以这里必须套 `glassGroup()`——玻璃采样不到
    /// 玻璃,不共享容器时紧挨着的两块亮度和折射对不上。
    ///
    /// 录音态(recordingBar)整行换成"取消 / 波形 / 确认"三段式,同样是三块形状、
    /// 同样的行高(共用 composerRowMinHeight),切换录音时这一行高度不变。
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
        // 录音条和输入条共用同一个最小高度:不拉平的话一按麦克风整行就缩一截、
        // 松开又弹回来。输入条多行时会超过这个值(文本框 1...5 行,照片缩略图行
        // 也在胶囊里),那时按内容走,不受这里限制。
        .frame(minHeight: Self.composerRowMinHeight)
        .animation(.lodoAware(.snappy(duration: 0.2)), value: speech.isRecording)
        // 同一行上的多块玻璃合进一个采样区(见上面的说明)。
        .glassGroup()
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// 输入栏控件行的固定高度(+ / 麦克风 / 发送 / 识别中 都按它取 frame)。
    private static let composerControlSize: CGFloat = 36
    /// 输入胶囊**里面**那颗(麦克风/发送/识别中)的尺寸。比外面的 + 小一档:
    /// 胶囊总高就是 36,里面再放一颗 36 的会顶满、上下不留缝。28 + 上下各 4 的
    /// 胶囊内边距正好 36,和左边那颗 + 同高。
    private static let composerInlineControlSize: CGFloat = 28
    /// 输入条与录音条共用的最小高度。拆成单行之后就等于控件本身的高度——
    /// + 号玻璃圆、输入胶囊、发送圆三块同高,整行没有别的东西再撑高它。
    /// (原来是 64:文本框一行 ≈ 22 + VStack 间距 6 + 底下那条控件行 36。)
    private static let composerRowMinHeight: CGFloat = composerControlSize

    /// 非录音态的一整行:[ + 玻璃圆 ][ 玻璃输入胶囊(末尾嵌着麦克风/发送) ]。
    /// 对齐取 `.bottom`——文本多行时胶囊往上长,左边那颗 + 要留在底边不跟着飘。
    private var composingBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
            textCapsule
        }
    }

    /// 独立的 + 号:自己一颗玻璃圆,不再是靠合并卡片衬底的纯图标。
    ///
    /// **这里不用 `.glassButton()`**(即 `.buttonStyle(.glass)`):理由和 sendButton
    /// 那段一样——系统按钮样式自带内容内边距和 HIG 最小触控尺寸,外面叠 .frame
    /// 收不住,会比右边麦克风/发送大一圈,而这一行三块形状必须同高。改成直接给
    /// 36pt 的标签铺一层 `glassBackground`,尺寸完全由这里的 frame 说了算,
    /// 「减弱透明度」也照样走 GlassBackground 那条不透明分支。
    /// 命中区仍用 hitTarget 补到 HIG 的 44pt(外观不变)。
    private var attachButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("照片", systemImage: "photo")
            }
            .disabled(remainingPhotoSlots == 0)
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
                .frame(width: Self.composerControlSize, height: Self.composerControlSize)
                .glassBackground(Circle())
                .hitTarget(visualSize: Self.composerControlSize)
        }
        .disabled(busy)
        .accessibilityLabel("添加附件")
    }

    /// 玻璃输入胶囊。照片缩略图行和麦克风/发送都在胶囊**里面**——照片和要发的
    /// 文字是同一条消息,视觉上该是一块;麦克风嵌在文本末尾而不是另立一颗,
    /// 胶囊会随照片/多行文本一起长高。
    ///
    /// 横向对齐取 `.bottom`,并且给文本那一列垫上和按钮一样的 minHeight:
    /// 单行时两者等高,底对齐即居中对齐;多行时文本往上长,按钮留在底边。
    private var textCapsule: some View {
        HStack(alignment: .bottom, spacing: 6) {
            textColumn
            trailingControl
        }
        .padding(.leading, 14)
        // 右边只留 4:里面那颗 28pt 的按钮自己就占掉了视觉上的"内边距"。
        .padding(.trailing, 4)
        // 上下各 4:28 的按钮 + 8 正好 36,和左边那颗 + 同高。
        .padding(.vertical, 4)
        .frame(minHeight: Self.composerControlSize)
        .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.composerRadius, style: .continuous))
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            photoPreviewRow
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
        }
        .frame(minHeight: Self.composerInlineControlSize)
    }

    /// 右边那个槽位:识别中 / 麦克风 / 发送,三态互斥、同尺寸同圆心。
    @ViewBuilder
    private var trailingControl: some View {
        Group {
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
        // 高度定死:打字时**只该换那颗按钮**,胶囊和文本不能跟着动。
        .frame(height: Self.composerInlineControlSize)
        .animation(.lodoAware(.snappy(duration: 0.2)), value: showsInlineMic)
        .animation(.lodoAware(.snappy(duration: 0.2)), value: speech.isProcessing)
    }

    /// 一次最多带几张照片。
    private static let maxPhotos = 5
    private static let photoThumbnailSize: CGFloat = 64

    /// 相册选进来的照片(按添加顺序),缩略图行和大图查看页共用。
    private var pendingImages: [PendingAttachment] {
        pendingAttachments.filter { $0.imageData != nil }
    }

    private var remainingPhotoSlots: Int {
        max(0, Self.maxPhotos - pendingImages.count)
    }

    /// 输入胶囊里、文本框上方的照片缩略图行:选了照片后胶囊随之长高,每张右上角
    /// ✕ 移除,点缩略图全屏看大图。放在胶囊**里面**而不是另起一行,照片和要发的
    /// 文字是同一条消息,视觉上也该是一块。
    @ViewBuilder
    private var photoPreviewRow: some View {
        let images = pendingImages
        if !images.isEmpty {
            HorizontalChipRow {
                ForEach(images) { attachment in
                    photoThumbnail(attachment)
                }
            }
            // ✕ 按钮往右上角探出去一截,给它留出位置,不被 ScrollView 裁掉。
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func photoThumbnail(_ attachment: PendingAttachment) -> some View {
        Button {
            viewingImage = ImageViewerTarget(id: attachment.id)
        } label: {
            ZStack {
                if let image = attachment.previewImage {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.fill.tertiary)
                }
                if attachment.isExtracting {
                    Rectangle().fill(.black.opacity(0.25))
                    ProgressView().tint(.white)
                }
            }
            .frame(width: Self.photoThumbnailSize, height: Self.photoThumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .pressable()
        .accessibilityLabel("查看图片")
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.lodoAware(.snappy(duration: 0.2))) {
                    removeAttachment(attachment)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .pressable()
            .accessibilityLabel("移除图片")
        }
        .padding(.top, 2)
    }

    /// 录音时整条输入条换成的"取消 / 波形 / 确认"胶囊,参考 iMessage/微信语音
    /// 消息录制条:左边取消(丢弃录音、不转写、不发送),中间波形随音量起伏,
    /// 右边确认(等同原先"录音中再点一次麦克风"——停止并走已有的自动发送流程)。
    private var recordingBar: some View {
        HStack(spacing: 8) {
            cancelRecordingButton
            RecordingWaveform(level: speech.audioLevel)
                .frame(maxWidth: .infinity)
                .frame(height: Self.composerControlSize)
                // 和非录音态的输入胶囊同一块形状、同一个圆角:切进切出录音时
                // 中间这块玻璃只是换了内容,不是换了一张卡。
                .glassBackground(
                    RoundedRectangle(cornerRadius: DesignMetrics.composerRadius, style: .continuous))
            confirmRecordingButton
        }
        // 写死行高而不是 maxHeight: .infinity——后者会一路撑满 safeAreaInset 给的
        // 空间,整条窜到半屏高。
        .frame(height: Self.composerControlSize)
    }

    private var cancelRecordingButton: some View {
        Button {
            speech.cancel()
            text = typedPrefix
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: Self.composerControlSize, height: Self.composerControlSize)
                // 和 + 号同一套独立玻璃圆:它俩是同一个槽位的两态。
                .glassBackground(Circle())
                .hitTarget(visualSize: Self.composerControlSize)
        }
        .pressable()
        .accessibilityLabel("取消录音")
    }

    private var confirmRecordingButton: some View {
        Button {
            speech.stop()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                // onFill 而不是写死白色:暗色下强调色是亮橙,白字只有 2.08。
                .foregroundStyle(lodoAccent.onFill)
                .frame(width: Self.composerControlSize, height: Self.composerControlSize)
                .background(lodoAccent.fill, in: Circle())
                .hitTarget(visualSize: Self.composerControlSize)
        }
        .pressable()
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
        /// 同 ShimmerText:静态读不会随设置变化重建视图,这里要的是反应式。
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let level: Float

        private static let barCount = 24
        private static let barWidth: CGFloat = 3
        private static let barSpacing: CGFloat = 3
        private static let minBarHeight: CGFloat = 4
        /// 峰值要收在 36pt 的玻璃胶囊里、上下各留一点余量(原来整条 40pt 高、
        /// 没有自己的形状,可以放到 34)。
        private static let maxBarHeight: CGFloat = 22
        /// 相邻条的相位间隔,决定"波浪流动"的疏密。
        private static let phaseStep: Double = 0.34
        /// 起伏一个完整周期的时长(秒)。
        private static let period: Double = 0.9
        /// 静音时仍保留的最小摆动幅度(0...1),避免完全静止。
        private static let idleAmplitude: Double = 0.18

        var body: some View {
            if reduceMotion {
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
            .frame(width: Self.composerInlineControlSize, height: Self.composerInlineControlSize)
            .contentShape(Rectangle())
            .accessibilityLabel("识别中")
    }

    /// 嵌在输入胶囊末尾的麦克风:纯图标,**不套玻璃**——它已经落在胶囊那层玻璃
    /// 上了,玻璃采样不到玻璃,再叠一层只会那一块失真。发送/完成录音仍是实心
    /// 强调色圆:主操作要压过玻璃这一档。
    ///
    /// 命中区照例补到 44pt。它会往左吃进文本框 8pt——这是内嵌按钮的固有取舍
    /// (系统自家的文本框内嵌按钮也一样),换来的是不必把可点区缩到 28pt。
    private var inlineMicButton: some View {
        Button {
            typedPrefix = text
            speech.toggle()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.composerInlineControlSize, height: Self.composerInlineControlSize)
                .hitTarget(visualSize: Self.composerInlineControlSize)
        }
        .pressable()
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .disabled(busy)
        .accessibilityLabel("语音输入")
    }

    /// busy 时按钮不再禁用,改成取消——点了就中断这次请求(输入区其余控件
    /// 如麦克风/附件继续保持 disabled(busy),不允许请求过程中改附件)。
    ///
    /// 这里**不用** `.glassProminentButton()`:那套(以及它在旧系统上回退到的
    /// .borderedProminent)自带一圈系统内容内边距 + HIG 最小触控尺寸,实测外面
    /// 叠 .frame 收不住、`.controlSize(.mini)` 也只压到 44 点上下,比左边的
    /// 麦克风大一圈——而这颗和麦克风是同一个槽位里互斥切换的两态,大小必须一样,
    /// 否则一打字按钮就"长大"一圈。换成和「完成录音」同款的实心强调色圆:
    /// 仍是系统控件(`.background(_:in: Circle())`),尺寸完全由这里的 frame 说了算。
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
                // busy 是灰底,仍用白字;强调色底走 onFill(理由同 confirmRecordingButton)。
                .foregroundStyle(busy ? AnyShapeStyle(Color.white)
                                      : AnyShapeStyle(lodoAccent.onFill))
                .frame(width: Self.composerInlineControlSize, height: Self.composerInlineControlSize)
                .background(busy ? AnyShapeStyle(.secondary) : AnyShapeStyle(lodoAccent.fill),
                            in: Circle())
                .hitTarget(visualSize: Self.composerInlineControlSize)
        }
        .pressable()
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(busy ? "取消" : "发送")
    }

    private var hasComposedContent: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !pendingAttachments.isEmpty
    }

    // MARK: - 消息

    /// excluding 为 nil 时不排除任何消息(询问卡回传选择那条路径没有用户气泡可排除)。
    /// 只取最近 `recentWindow` 条逐条回传;更早的由 `AgentConversationSummary`
    /// 压成一段摘要另外拼进 prompt,不在这里带。
    private func recentHistory(excluding: AgentMessage?) -> [(role: String, content: String)] {
        let excludeUUID = excluding?.uuid
        // 倒序 + fetchLimit,不是全表取回来再 suffix:对话永不结束,全表取数
        // 会随着聊天次数一路变慢,而且就发生在发送这条主路径上。多取一条是给
        // 要排除的那条(刚插进去的用户气泡)留的位。
        var descriptor = FetchDescriptor<AgentMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = AgentConversationSummary.recentWindow + 1
        let recent = ((try? context.fetch(descriptor)) ?? []).reversed()
        return recent.filter { $0.uuid != excludeUUID }
            .suffix(AgentConversationSummary.recentWindow)
            .map { (role: $0.roleRaw, content: $0.content) }
    }

    /// 窗口之外积够一批就把它们压成常驻摘要(`AgentConversationSummary`)。
    ///
    /// **在这一轮回复落库之后触发,不是发送之前**:压缩自己也是一次网络请求,
    /// 放在发送前会给这一轮平白加一次串行等待,而这一轮用上一次压出来的摘要
    /// 本来就够——差一个批次不影响理解。整段照 `AgentPreferences.consolidateIfNeeded`
    /// 的姿态:fire-and-forget,没配 key/断网/解析失败一律静默跳过、保持原样
    /// (水位线不动,下一轮再试),绝不冒泡到 errorText 打断主流程。
    private func compactHistoryIfNeeded() {
        guard DeepSeekClient.isConfigured, !isCompacting else { return }
        let covered = AgentConversationSummary.coveredUntil

        // 两次都是有上界的取数(理由同 recentHistory:全表取数会随聊天次数
        // 一路变慢,而这段就跑在每次发送之后)。
        // ① 先定出窗口起点 = 倒数第 recentWindow 条的时间。
        var windowDescriptor = FetchDescriptor<AgentMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        windowDescriptor.fetchLimit = AgentConversationSummary.recentWindow
        let window = (try? context.fetch(windowDescriptor)) ?? []
        // 总共还不够一个窗口,窗口之外什么都没有。
        guard window.count == AgentConversationSummary.recentWindow,
              let windowStart = window.last?.createdAt else { return }

        // ② 窗口之外、且还没压过的那些。一次最多压这么多,剩下的下一轮再压——
        // 不设上界的话,长期没联网攒下的一大批会一次性全塞进 prompt。
        var pendingDescriptor = FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> {
                $0.createdAt > covered && $0.createdAt < windowStart
            },
            sortBy: [SortDescriptor(\.createdAt)])
        pendingDescriptor.fetchLimit = Self.maxCompressBatch
        let pending = (try? context.fetch(pendingDescriptor)) ?? []
        guard pending.count >= AgentConversationSummary.compressBatch else { return }

        // ModelContext 不跨线程:先在主线程把要压的内容取成纯值,再进后台任务。
        let transcript = pending
            .map { "\($0.roleRaw == "user" ? "用户" : "助手"):\($0.content)" }
            .joined(separator: "\n")
        guard let until = pending.last?.createdAt else { return }
        let previous = AgentConversationSummary.content
        let total = AgentConversationSummary.coveredCount + pending.count

        isCompacting = true
        Task { @MainActor in
            defer { isCompacting = false }
            guard let summary = try? await DeepSeekClient.summarizeConversation(
                previous: previous, transcript: MemorySearch.truncate(transcript, limit: 8000))
            else { return }
            AgentConversationSummary.save(summary, coveredUntil: until, coveredCount: total)
        }
    }

    @discardableResult
    private func appendAssistant(
        kind: AgentMessageKind, content: String,
        relatedTitles: [String] = [], askSnapshotData: Data? = nil,
        taskSnapshotData: Data? = nil, resultMemoryUUID: UUID? = nil,
        tripPlanSnapshotData: Data? = nil, tripEditSnapshotData: Data? = nil
    ) -> AgentMessage {
        let message = AgentMessage(role: .assistant, kind: kind,
                                   content: content, relatedTitles: relatedTitles,
                                   askSnapshotData: askSnapshotData, taskSnapshotData: taskSnapshotData,
                                   resultMemoryUUID: resultMemoryUUID,
                                   tripPlanSnapshotData: tripPlanSnapshotData,
                                   tripEditSnapshotData: tripEditSnapshotData)
        context.insert(message)
        try? context.save()
        return message
    }

    /// 规划卡片。content 存一段纯文字版的规划:对话历史(recentHistory)只取
    /// content 回传给模型,用户接着说"第二天轻松点"时,模型要看得到上一份排了什么。
    private func appendTripPlan(plan: TripPlanProposal) {
        appendAssistant(
            kind: .tripPlan,
            content: TravelPlan.promptSummary(tripTitle: plan.tripTitle, days: plan.days(),
                                              entries: plan.entries),
            tripPlanSnapshotData: try? JSONEncoder().encode(plan))
    }

    /// 新建/修改落库后的只读结果卡片。新建和修改都已经**先落库再报告**,这张卡
    /// 是事后反悔的入口(新建给 ✕、修改给撤销,见 AgentMessageBubble)。
    /// taskProposal(先出提案、点了"确认新建"才落库)那条老路径不再产生新消息,
    /// 但老对话里已经存下的那些仍然照常渲染、按钮照常可用。
    private func appendTaskResult(existingUUID: UUID?, parsed: ParsedTask,
                                  createdUUID: UUID? = nil) {
        let snapshot = AgentTaskSnapshot(existingUUID: existingUUID, parsed: parsed,
                                         createdUUID: createdUUID)
        appendAssistant(kind: .taskResult,
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
        guard let data = message.taskSnapshotData,
              let snapshot = try? JSONDecoder().decode(AgentTaskSnapshot.self, from: data)
        else { return }
        saveTask(existingTask(for: snapshot.existingUUID), snapshot.parsed)
        appendTaskResult(existingUUID: snapshot.existingUUID, parsed: snapshot.parsed)
    }

    private func handleTaskProposalCancel(_ message: AgentMessage) {
        appendAssistant(kind: .text, content: "已取消这次操作。")
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
        guard let data = message.askSnapshotData,
              var snapshot = try? JSONDecoder().decode(AgentAskSnapshot.self, from: data)
        else { return }
        snapshot.answers = answers
        message.kindRaw = AgentMessageKind.askResult.rawValue
        message.askSnapshotData = try? JSONEncoder().encode(snapshot)
        message.content = snapshot.transcript
        try? context.save()
        send(overrideText: "(用户已回答上面的问题)\n\(snapshot.transcript)", hidesUserBubble: true)
    }

    private func handleAskCancel(_ message: AgentMessage) {
        appendAssistant(kind: .text, content: "已取消这次提问。")
    }

    private func handleConfirmAction(_ message: AgentMessage, execute: Bool) {
        if execute {
            onConfirm()
            appendAssistant(kind: .executed, content: "已完成执行")
        } else {
            appendAssistant(kind: .text, content: "已取消这次操作。")
        }
    }

    /// "已完成执行"气泡上的撤销按钮;结果(成功/没有可撤销的操作)追加成一条
    /// 新的回答消息,和用户直接打字"撤销"走同一条展示路径。
    private func handleUndo() {
        if case .answer(let text, let related) = onUndo() {
            appendAssistant(kind: .answer, content: text, relatedTitles: related)
        }
    }

    /// 新建结果卡片的开关:有效 → 删掉事项、对号变灰 ✕;已取消 → 按同一份快照
    /// 重新建一条(uuid 是新的,写回快照,卡片据此回到蓝色对号)。改写
    /// taskSnapshotData 同时也是让这条气泡重新渲染的触发点——@Query 盯的是消息,
    /// 光删掉那个 TaskItem 不会让气泡刷新。
    private func handleToggleCreatedTask(_ message: AgentMessage) {
        guard let data = message.taskSnapshotData,
              var snapshot = try? JSONDecoder().decode(AgentTaskSnapshot.self, from: data),
              snapshot.createdUUID != nil
        else { return }
        let newUUID = toggleCreatedTask(snapshot.isCreatedActive ? snapshot.createdUUID : nil,
                                        snapshot.parsed)
        snapshot.createdRemoved = (newUUID == nil)
        if let newUUID { snapshot.createdUUID = newUUID }
        message.taskSnapshotData = try? JSONEncoder().encode(snapshot)
        try? context.save()
        Haptics.tick()
    }

    /// 记忆结果卡片右边那颗 ✕:收藏(以及 AI 自动记录)也是**默认就存**,这颗
    /// 是事后反悔的入口。直接把这条消息原地改写成一句纯文本——条目删掉之后卡片
    /// 本来就渲染不出来了(memoryResultContent 查不到 item),留着"已收藏"四个字
    /// 反而对不上账。走 MemoryPipeline.delete,连同向量分片一起清掉。
    private func handleCancelMemoryResult(_ message: AgentMessage) {
        guard let uuid = message.resultMemoryUUID,
              let item = (try? context.fetch(FetchDescriptor<MemoryItem>(
                  predicate: #Predicate<MemoryItem> { $0.uuid == uuid })))?.first
        else { return }
        MemoryPipeline.delete(item, context: context)
        message.resultMemoryUUID = nil
        message.kindRaw = AgentMessageKind.text.rawValue
        message.content = "已取消收藏。"
        try? context.save()
    }

    /// "收藏这条"按钮:AI 主动建议、用户确认后才真正落库,展示形态和 memorize
    /// 分支(route() 里)一致的记忆结果卡片。
    private func handleMemorizeSuggestion(_ message: AgentMessage) {
        let item = MemoryPipeline.saveText(message.content, context: context)
        appendAssistant(kind: .memoryResult, content: "已收藏",
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

    /// 选好就先把缩略图摆出来(OCR 可能要一两秒,不能让人以为没选上),
    /// 识别完再把文字补进同一个附件;识别期间缩略图上转圈,发送按钮等它识别完。
    private func handlePickedImage(_ data: Data) {
        guard remainingPhotoSlots > 0 else { return }
        let stored = Self.normalizedImageData(data)
        let item = MemoryPipeline.saveImageData(stored, context: context)
        let attachment = PendingAttachment(
            displayName: "图片", extractedText: "", memoryUUID: item?.uuid,
            symbol: "photo", isNewlyCreated: true, imageData: stored, isExtracting: true)
        withAnimation(.lodoAware(.snappy(duration: 0.2))) {
            pendingAttachments.append(attachment)
        }
        Task {
            var extractedText = ""
            if let item, let url = MemoryPipeline.fileURL(of: item) {
                extractedText = await ContentExtractor.extract(fileURL: url).text
            }
            // 识别期间可能已经被 ✕ 掉或随消息发出去了,找不到就算了。
            guard let index = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) else { return }
            pendingAttachments[index].extractedText = extractedText
            pendingAttachments[index].isExtracting = false
        }
    }

    /// 相册里的照片可能是 HEIC、分辨率很高;转成 JPEG 再存,附件不至于一张十几 MB
    /// (和 MenuImportView.normalized 同一个理由)。
    private static func normalizedImageData(_ data: Data) -> Data {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
        #else
        return data
        #endif
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

    #if DEBUG
    private func seedDemoPhotos() {
        #if os(iOS)
        let colors: [UIColor] = [.systemOrange, .systemTeal, .systemPink]
        for (index, color) in colors.enumerated() {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                ("照片 \(index + 1)" as NSString).draw(
                    at: CGPoint(x: 180, y: 360),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white])
            }
            if let data = image.jpegData(compressionQuality: 0.8) { handlePickedImage(data) }
        }
        isInputFocused = false
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-photo-viewer"),
           let second = pendingImages.dropFirst().first {
            viewingImage = ImageViewerTarget(id: second.id)
        }
        #endif
    }
    #endif

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
        let cutoff = message.createdAt
        let toDelete = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate<AgentMessage> { $0.createdAt >= cutoff }))) ?? []
        for item in toDelete { context.delete(item) }
        try? context.save()
        // 截断到摘要水位线以内时把摘要作废:被删掉的那几条已经压进摘要了,
        // 留着它就等于让模型继续记着一段用户刚亲手删掉的对话。下一轮会重压。
        if cutoff <= AgentConversationSummary.coveredUntil {
            AgentConversationSummary.reset()
        }
        if let quoted = quotedMessage, toDelete.contains(where: { $0.uuid == quoted.uuid }) {
            quotedMessage = nil
        }
        text = message.content
        isInputFocused = true
    }

    // MARK: - 提交

    /// hidesUserBubble:这次提交不代表用户"说了一句话",不插用户气泡
    /// (询问卡答完后回传选择就走这条路——对话里留下的是那张记录卡,
    /// 再冒一条内容重复的蓝气泡反而啰嗦)。其余流程(busy/取消/思考提示/错误)
    /// 与正常发送完全一致。
    private func send(overrideText: String? = nil, hidesUserBubble: Bool = false) {
        let trimmed = (overrideText ?? text).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 0 || !pendingAttachments.isEmpty, !busy,
              !pendingAttachments.contains(where: \.isExtracting) else { return }
        speech.stop()
        busy = true
        // 上一次的报错不该跨过这次发送继续挂在输入栏上面。语音那条尤其要在这里清:
        // SpeechInput 自己只在重新开始录音时清 errorText,不再开麦就一直留着。
        errorText = nil
        speech.errorText = nil

        let attachments = pendingAttachments
        pendingAttachments = []
        let quoted = quotedMessage
        quotedMessage = nil
        text = ""

        var userMessage: AgentMessage?
        if !hidesUserBubble {
            let message = AgentMessage(
                role: .user, content: trimmed,
                attachmentMemoryUUIDs: attachments.compactMap(\.memoryUUID),
                quotedContent: quoted?.content)
            context.insert(message)
            userMessage = message
        }
        try? context.save()

        let history = recentHistory(excluding: userMessage)
        var outgoing = trimmed
        if let quoted {
            outgoing = "引用消息:「\(quoted.content)」\n\n" + outgoing
        }
        for attachment in attachments {
            // 照片是在端上 OCR 成文字发出去的,图片本身不上传。一个字都没认出来时
            // 说明白(而不是留个空附件),模型才好据此回话,不至于以为自己看得见图。
            let body = attachment.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                outgoing += "\n\n[附件:\(attachment.displayName),没有识别出文字]"
            } else {
                outgoing += "\n\n[附件:\(attachment.displayName)]\n\(body)"
            }
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
                streamingAnswer = nil
                reasoningTail = ""
                sendTask = nil
            }
            do {
                // submit 是个闭包属性,形参没有标签,所以三个回调只能按位置传
                // (多重尾随闭包要求被调用方在类型里声明标签)。
                let reply = try await submit(
                    outgoing, history,
                    { thought in thinkingText = thought },
                    { text in
                        // 空串 = 流式失败要回退,把已经显示的半句收掉。
                        streamingAnswer = text.isEmpty ? nil : text
                        if streamingAnswer != nil { thinkingText = nil }
                    },
                    { chunk in
                        // 推理模型先吐思考再吐正文,这段空窗期比正文本身还长。
                        // 只显示尾巴一小截(够看出"它在想什么"),不落库。
                        reasoningTail = String((reasoningTail + chunk).suffix(40))
                        if streamingAnswer == nil { thinkingText = reasoningTail }
                    })
                // 拿到结果时可能已经被用户取消——不再落库/弹表单,避免取消瞬间
                // 又把回应加回来。
                guard !Task.isCancelled else { return }
                switch reply {
                case .created(let task, let parsed):
                    appendTaskResult(existingUUID: nil, parsed: parsed,
                                     createdUUID: task.uuid)
                case .updated(let task, let parsed):
                    appendTaskResult(existingUUID: task.uuid, parsed: parsed)
                case .confirm(let lines):
                    appendAssistant(kind: .confirm, content: lines.joined(separator: "\n"))
                case .ask(let questions):
                    let snapshot = AgentAskSnapshot(questions: questions)
                    appendAssistant(
                        kind: .ask,
                        content: questions.map(\.question).joined(separator: "\n"),
                        askSnapshotData: try? JSONEncoder().encode(snapshot))
                case .answer(let text, let related):
                    appendAssistant(kind: .answer, content: text, relatedTitles: related)
                case .suggestMemorize(let text):
                    appendAssistant(kind: .memorizeSuggestion, content: text)
                case .memorized(let uuid):
                    appendAssistant(kind: .memoryResult, content: "已收藏",
                                    resultMemoryUUID: uuid)
                case .autoMemorized(let uuid):
                    appendAssistant(kind: .memoryResult, content: "已自动记录",
                                    resultMemoryUUID: uuid)
                case .tripPlan(let plan):
                    appendTripPlan(plan: plan)
                case .tripEdited(let record):
                    appendAssistant(kind: .tripEdit, content: record.transcript,
                                    tripEditSnapshotData: try? JSONEncoder().encode(record))
                }
                compactHistoryIfNeeded()
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
        streamingAnswer = nil
        reasoningTail = ""
    }

    #if DEBUG
    /// 截图验证用:模拟确认清单 / 反问 / 回答三种回应态。
    private func seedDemoMessagesIfNeeded() {
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-confirm") {
            appendAssistant(kind: .confirm,
                            content: "新建:开周会(明天 15:00 · 60 分钟)\n完成:给妈妈回电话\n删除:取快递")
        }
        // 询问卡:三道题(单选 + 多选各有),覆盖翻页器、推荐角标、其他输入框。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-ask") {
            context.insert(AgentMessage(role: .user, content: "提醒我交材料"))
            appendAssistant(
                kind: .ask,
                content: Self.demoAskSnapshot.questions.map(\.question).joined(separator: "\n"),
                askSnapshotData: try? JSONEncoder().encode(Self.demoAskSnapshot))
        }
        // 答完之后的记录卡。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-ask-result") {
            context.insert(AgentMessage(role: .user, content: "提醒我交材料"))
            var answered = Self.demoAskSnapshot
            answered.answers = [["明天 09:00"], ["30 分钟"], ["身份证", "复印件"]]
            appendAssistant(kind: .askResult, content: answered.transcript,
                            askSnapshotData: try? JSONEncoder().encode(answered))
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-answer") {
            context.insert(AgentMessage(role: .user, content: "我之前存的 wifi 密码"))
            appendAssistant(kind: .answer, content: "你收藏的 wifi 密码是 8888。",
                            relatedTitles: ["家里 wifi 密码"])
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-executed") {
            context.insert(AgentMessage(role: .user, content: "把开会删了"))
            appendAssistant(kind: .executed, content: "已完成执行")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-memorize-suggestion") {
            context.insert(AgentMessage(role: .user, content: "我周三下午一般没空"))
            appendAssistant(kind: .memorizeSuggestion, content: "用户周三下午通常没有空闲时间")
        }
        // 老对话里那种"先出提案、点确认才落库"的卡片。新流程不再产生它(新建
        // 默认直接落库),但老库里存着的仍要能正常渲染——这个 demo 就是拿来回归
        // 那条兼容路径的,所以消息在这儿手搓,不再留一个只有它在用的生产方法。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-proposal") {
            context.insert(AgentMessage(role: .user, content: "明天下午3点开会,60分钟"))
            let snapshot = AgentTaskSnapshot(existingUUID: nil, parsed: Self.demoParsedTask)
            appendAssistant(kind: .taskProposal, content: "新建",
                            taskSnapshotData: try? JSONEncoder().encode(snapshot))
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-result") {
            context.insert(AgentMessage(role: .user, content: "明天下午3点开会,60分钟"))
            appendTaskResult(existingUUID: nil, parsed: Self.demoParsedTask,
                             createdUUID: UUID())
        }
        // 新建结果卡片被点掉之后的样子(灰色 ✕ + "已取消新建")。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-result-removed") {
            context.insert(AgentMessage(role: .user, content: "明天下午3点开会,60分钟"))
            let snapshot = AgentTaskSnapshot(existingUUID: nil, parsed: Self.demoParsedTask,
                                             createdUUID: UUID(), createdRemoved: true)
            appendAssistant(kind: .taskResult, content: "已新建",
                            taskSnapshotData: try? JSONEncoder().encode(snapshot))
        }
        // 修改结果卡片(带撤销按钮),和上面新建结果卡片(带对号开关)对照截图用。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-task-result-updated") {
            context.insert(AgentMessage(role: .user, content: "开会挪到下午4点"))
            appendTaskResult(existingUUID: UUID(), parsed: Self.demoParsedTask)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-trip-plan") {
            context.insert(AgentMessage(role: .user, content: "帮我规划一下京都三天"))
            appendTripPlan(plan: Self.demoTripPlan)
        }
        // 写入之后的样子:真的走一遍 TravelStore.applyPlan,旅行页里能看到这次旅行。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-trip-plan-applied") {
            context.insert(AgentMessage(role: .user, content: "帮我规划一下京都三天"))
            let applied = TravelStore.applyPlan(Self.demoTripPlan, context: context)
            appendAssistant(
                kind: .tripPlan, content: "已写入",
                tripPlanSnapshotData: try? JSONEncoder().encode(applied))
        }
        // 调整结果卡片:先把样板规划写进旅行,再真的执行一次"第二天改去奈良"。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-trip-edit") {
            let applied = TravelStore.applyPlan(Self.demoTripPlan, context: context)
            context.insert(AgentMessage(role: .user,
                                        content: "京都第二天不去岚山了,改去奈良"))
            let calendar = Calendar.current
            let day2 = calendar.date(byAdding: .day, value: 1, to: applied.startDate)!
            func at(_ hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: day2)! }
            let removeIDs = TravelStore.items(for: applied.appliedTripUUID!, in: context)
                .filter { $0.title == "岚山竹林小径" || $0.title == "天龙寺" }
                .map(\.uuid)
            let edit = TripEdit(
                tripTitle: "京都三日", summary: "第二天换成奈良:上午东大寺,下午奈良公园喂鹿。",
                removeIDs: removeIDs,
                additions: [
                    TripPlanItem(kind: .place, title: "东大寺", note: "近铁奈良站步行 20 分钟。",
                                 start: at(10), end: at(12), placeName: "东大寺"),
                    TripPlanItem(kind: .place, title: "奈良公园", note: "鹿仙贝在公园里的小摊买。",
                                 start: at(13), end: at(15), placeName: "奈良公园"),
                ])
            if var record = TravelStore.applyEdit(edit, context: context) {
                // 撤销之后的样子,同时验证 revertEdit 真的把行程改回去了(去旅行页按天看)。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-trip-edit-reverted") {
                    record = TravelStore.revertEdit(record, context: context)
                }
                appendAssistant(kind: .tripEdit, content: record.transcript,
                                tripEditSnapshotData: try? JSONEncoder().encode(record))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-memory-result") {
            context.insert(AgentMessage(role: .user, content: "记住wifi密码是8888"))
            let item = MemoryPipeline.saveText("wifi密码是8888", context: context)
            appendAssistant(kind: .memoryResult, content: "已收藏",
                            resultMemoryUUID: item?.uuid)
        }
        // 打字机动画:插入一条 createdAt 晚于 typingBaseline 的 .text 回复,
        // 触发逐字显示 + 逐字振动(和加载已有历史消息时的"整段直接显示"对照)。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-text-reply") {
            context.insert(AgentMessage(role: .user, content: "帮我看看今天忙不忙"))
            appendAssistant(kind: .text,
                            content: "今天你只有一件事——下午3点开会,其余时间都空着,可以安排点别的。")
        }
        // 用户气泡带引用摘要(quote.bubble 图标 + 单行截断),对照气泡渲染用。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-quoted") {
            let quoted = AgentMessage(role: .assistant,
                                      content: "你收藏的 wifi 密码是 8888。")
            context.insert(quoted)
            context.insert(AgentMessage(role: .user, content: "谢谢",
                                        quotedContent: quoted.content))
        }
        // 截图验证用:塞满一页多的历史,看列表窗口化和顶上那颗「载入更早的对话」。
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-history") {
            let base = Date().addingTimeInterval(-Double(Self.historyPageSize) * 120)
            for index in 0..<(Self.historyPageSize + 20) {
                let message = AgentMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: index.isMultiple(of: 2) ? "第 \(index / 2 + 1) 句" : "好的。")
                message.createdAt = base.addingTimeInterval(Double(index) * 60)
                context.insert(message)
            }
            try? context.save()
        }
    }

    /// 规划卡片的样板:京都三日,从三天后开始。
    private static var demoTripPlan: TripPlanProposal {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Date()))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: day * 1440 + hour * 60 + minute, to: start)!
        }
        return TripPlanProposal(
            tripTitle: "京都三日",
            startDate: start,
            endDate: at(2, 0),
            summary: "第一天东山步行,第二天岚山,第三天伏见稻荷后离开;住四条河原町,去哪都方便。",
            items: [
                TripPlanItem(kind: .lodging, title: "住四条河原町一带", note: "地铁、巴士、京阪都在附近。",
                             start: at(0, 15), end: at(2, 11), placeName: "四条河原町"),
                TripPlanItem(kind: .place, title: "清水寺", note: "从五条坂上去,顺着二年坂、三年坂往下走。",
                             start: at(0, 16), end: at(0, 17, 30), placeName: "清水寺",
                             price: 500, currency: "JPY"),
                TripPlanItem(kind: .place, title: "祇园 花见小路", note: "傍晚灯亮起来最好看,晚饭就在附近吃。",
                             start: at(0, 18), end: at(0, 20), placeName: "花见小路"),
                TripPlanItem(kind: .place, title: "岚山竹林小径", note: "早上 8 点前人少。",
                             start: at(1, 8), end: at(1, 9), placeName: "竹林小径"),
                TripPlanItem(kind: .place, title: "天龙寺", start: at(1, 9, 30), end: at(1, 11),
                             placeName: "天龙寺", price: 800, currency: "JPY"),
                TripPlanItem(kind: .place, title: "伏见稻荷大社", note: "千本鸟居走到四辻就够了,来回一个半小时。",
                             start: at(2, 7, 30), end: at(2, 9, 30), placeName: "伏见稻荷大社"),
            ])
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
    /// 相册选的照片原图数据(缩略图/大图查看用);文件、记忆库条目为 nil。
    var imageData: Data? = nil
    /// 照片还在端上 OCR,识别完才能发送。
    var isExtracting: Bool = false

    var previewImage: Image? {
        guard let imageData else { return nil }
        #if os(iOS)
        return UIImage(data: imageData).map { Image(uiImage: $0) }
        #else
        return NSImage(data: imageData).map { Image(nsImage: $0) }
        #endif
    }
}

private struct ImageViewerTarget: Identifiable {
    let id: UUID
}

/// 点输入卡片里的缩略图打开的大图查看页:黑底,左右滑动切换这次要发的几张照片,
/// 点图片以外的空白处回到对话。
/// 导航栏正中两行:对话标题 + 第二行「服务商 · token 用量/速度」(还没发过请求时
/// 后半截是联网搜索这类能力标记)。恒定渲染、只淡出内容——导航栏高度才不会
/// 跟着抽屉/右栏开合跳变。
private struct AgentTitleView: View {
    let title: String
    /// 当前服务商。
    let mode: String
    /// 联网搜索这类能力标记;有 token 指标时被它顶掉。
    let capability: String?
    @Environment(\.sidebarChrome) private var chrome
    /// token 用量/速度。**故意在这个子视图里读**:每 0.25s 跳一次数字,
    /// 在 AgentView.body 里读会把整条 chatStack 跟着重建,这里只重建导航栏这两行。
    private let usage = AIUsageMonitor.shared

    private var hides: Bool { chrome?.hidesChrome ?? false }

    private var subtitle: String {
        [mode, usage.turn?.badge ?? capability]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .opacity(hides ? 0 : 1)
        .accessibilityHidden(hides)
    }
}

private struct AgentImageViewer: View {
    let images: [PendingAttachment]
    @State private var selection: UUID
    @Environment(\.dismiss) private var dismiss

    init(images: [PendingAttachment], initialID: UUID) {
        self.images = images
        self._selection = State(initialValue: initialID)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            pager
            if images.count > 1, let index = images.firstIndex(where: { $0.id == selection }) {
                VStack {
                    Spacer()
                    Text("\(index + 1) / \(images.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.15), in: Capsule())
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
        .onChange(of: images.map(\.id)) { _, ids in
            if ids.isEmpty { dismiss() }
        }
    }

    @ViewBuilder
    private var pager: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(images) { attachment in
                page(attachment).tag(attachment.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        #else
        // macOS 没有翻页式 TabView,用左右箭头切换。
        if let index = images.firstIndex(where: { $0.id == selection }) {
            HStack {
                Button { selection = images[max(0, index - 1)].id } label: {
                    Image(systemName: "chevron.left").font(.title)
                }
                .disabled(index == 0)
                page(images[index])
                Button { selection = images[min(images.count - 1, index + 1)].id } label: {
                    Image(systemName: "chevron.right").font(.title)
                }
                .disabled(index == images.count - 1)
            }
            .pressable()
            .foregroundStyle(.white)
            .padding()
        }
        #endif
    }

    /// 图片本身吞掉点击(不关页面),图片周围的空白区域点了才关。
    private func page(_ attachment: PendingAttachment) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
            attachment.previewImage?
                .resizable()
                .scaledToFit()
                .onTapGesture {}
        }
    }
}

/// 单条新建/修改弹出的表单目标。
private struct FormTarget: Identifiable {
    let id = UUID()
    let existing: TaskItem?
    let parsed: ParsedTask
}

/// 消息列表。对话是单一持续时间线、永不结束,所以**倒序取最近 historyWindow 条**
/// 再翻回正序展示,而不是把整条历史灌进 @Query(AI 页还是冷启动的落地页,那样
/// 每次启动都要把全部消息实例化一遍)。窗口大小是动态 descriptor,父视图用
/// `.id(historyWindow)` 强制这个子视图在换页时重建——正是原来按 thread 建
/// @Query 时 `.id(thread.uuid)` 那一套写法。
private struct AgentMessageListView: View {
    let historyWindow: Int
    /// 流式回复的临时预览;非 nil 时渲染在列表末尾(不落库)。
    let streamingAnswer: String?
    /// 顶上那颗「载入更早的对话」:父视图把窗口加一页。
    let onLoadEarlier: () -> Void
    let onConfirmAction: (AgentMessage, Bool) -> Void
    let onUndo: () -> Void
    let onMemorizeSuggestion: (AgentMessage) -> Void
    let onCancelMemoryResult: (AgentMessage) -> Void
    let onToggleCreatedTask: (AgentMessage) -> Void
    let onTaskProposalConfirm: (AgentMessage) -> Void
    let onTaskProposalCancel: (AgentMessage) -> Void
    let onTaskProposalTap: (AgentMessage) -> Void
    let onAskSubmit: (AgentMessage, [[String]]) -> Void
    let onAskCancel: (AgentMessage) -> Void
    let onExamplePrompt: (String) -> Void
    let onCopy: (AgentMessage) -> Void
    let onQuote: (AgentMessage) -> Void
    let onEdit: (AgentMessage) -> Void
    /// 最后一条是不是还没答的询问卡。消息列表在这儿(@Query 在这个 struct 上),
    /// 由它报给外层决定输入区收不收起来。
    let onPendingAskChange: (Bool) -> Void

    @Query private var messages: [AgentMessage]

    /// @Query 取的是倒序(为了 fetchLimit 能截到**最近** historyWindow 条),
    /// 展示前翻回正序。
    private var ordered: [AgentMessage] { messages.reversed() }
    /// 还有更早的没载进来:这一页取满了就假定上面还有。
    private var hasEarlier: Bool { messages.count >= historyWindow }
    /// 最后一条是待答的询问卡(答完/取消后它会变成 askResult 或后面追加新消息,
    /// 这个值随即变 false)。
    private var hasPendingAsk: Bool { messages.first?.kind == .ask }

    /// 这个视图这次构建的时间点;晚于它 createdAt 的 .text 回复才播打字机
    /// 动画("这次会话里刚收到的新回复"),早于它的历史消息一律整段直接显示。
    /// 换页(.id(historyWindow))时会连带 @State 一起重建、把它推到"点载入更早
    /// 那一刻",但载进来的都是更老的消息,照样不播,所以不用额外重置逻辑。
    @State private var typingBaseline = Date()

    init(historyWindow: Int, streamingAnswer: String?, onLoadEarlier: @escaping () -> Void,
         onConfirmAction: @escaping (AgentMessage, Bool) -> Void,
         onUndo: @escaping () -> Void, onMemorizeSuggestion: @escaping (AgentMessage) -> Void,
         onCancelMemoryResult: @escaping (AgentMessage) -> Void,
         onToggleCreatedTask: @escaping (AgentMessage) -> Void,
         onTaskProposalConfirm: @escaping (AgentMessage) -> Void,
         onTaskProposalCancel: @escaping (AgentMessage) -> Void,
         onTaskProposalTap: @escaping (AgentMessage) -> Void,
         onAskSubmit: @escaping (AgentMessage, [[String]]) -> Void,
         onAskCancel: @escaping (AgentMessage) -> Void,
         onExamplePrompt: @escaping (String) -> Void,
         onCopy: @escaping (AgentMessage) -> Void,
         onQuote: @escaping (AgentMessage) -> Void,
         onEdit: @escaping (AgentMessage) -> Void,
         onPendingAskChange: @escaping (Bool) -> Void) {
        self.historyWindow = historyWindow
        self.streamingAnswer = streamingAnswer
        self.onLoadEarlier = onLoadEarlier
        self.onConfirmAction = onConfirmAction
        self.onUndo = onUndo
        self.onMemorizeSuggestion = onMemorizeSuggestion
        self.onCancelMemoryResult = onCancelMemoryResult
        self.onToggleCreatedTask = onToggleCreatedTask
        self.onTaskProposalConfirm = onTaskProposalConfirm
        self.onTaskProposalCancel = onTaskProposalCancel
        self.onTaskProposalTap = onTaskProposalTap
        self.onAskSubmit = onAskSubmit
        self.onAskCancel = onAskCancel
        self.onExamplePrompt = onExamplePrompt
        self.onCopy = onCopy
        self.onQuote = onQuote
        self.onEdit = onEdit
        self.onPendingAskChange = onPendingAskChange
        var descriptor = FetchDescriptor<AgentMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = historyWindow
        _messages = Query(descriptor)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    if hasEarlier {
                        Button("载入更早的对话", action: onLoadEarlier)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(ordered) { message in
                        AgentMessageBubble(
                            message: message, isLatest: message.uuid == messages.first?.uuid,
                            onConfirm: { onConfirmAction(message, true) },
                            onCancelConfirm: { onConfirmAction(message, false) },
                            onUndo: onUndo,
                            onMemorizeSuggestion: { onMemorizeSuggestion(message) },
                            onCancelMemoryResult: { onCancelMemoryResult(message) },
                            onToggleCreatedTask: { onToggleCreatedTask(message) },
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
                    // 流式预览排在最后一条之后。放在滚动流里而不是像
                    // thinkingRow 那样贴在输入栏上方:长回复要能正常往上滚。
                    if let streamingAnswer {
                        AgentAnswerCard(text: streamingAnswer)
                            .id(Self.streamingID)
                    }
                }
                .padding()
                // 对话里挨着的玻璃不止一处:结果卡片自己是玻璃底,卡片下面那排
                // 「确认/写入」又是高亮玻璃,连着两条带卡片的消息更是上下贴着。
                // 整列合进一个容器共享采样,既让这些玻璃看起来是同一层材质,也
                // 免得每块各建一个 CABackdropLayer(滚动时是实打实的开销)。
                // 容器不影响布局,下面的 frame/animation 照旧。
                .glassGroup()
                .animation(.lodoAware(.snappy), value: messages.count)
                // 内容比屏幕短时也把这一坨顶到底部,最后一条消息紧挨着输入栏
                // ——短对话原来是从顶上开始排,和输入栏之间空出一大片。
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            // 一打开就停在最后一条(不是从头开始往下找)。onAppear 里那句
            // scrollTo 是兜底:LazyVStack 首帧还没把最后一条建出来时,单靠
            // scrollTo 会落空。
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                if let last = messages.first {
                    withAnimation(.lodoAware(.snappy)) { proxy.scrollTo(last.uuid, anchor: .bottom) }
                }
            }
            // 流式期间一直贴着底,新吐出来的字不会被输入栏挡住。不带动画:
            // 每隔 80ms 就来一次,叠动画会一路抖。
            .onChange(of: streamingAnswer) { _, text in
                guard text != nil else { return }
                proxy.scrollTo(Self.streamingID, anchor: .bottom)
            }
            .onAppear {
                if let last = messages.first { proxy.scrollTo(last.uuid, anchor: .bottom) }
                onPendingAskChange(hasPendingAsk)
            }
            .onChange(of: hasPendingAsk) { _, pending in onPendingAskChange(pending) }
        }
    }

    /// 流式预览气泡的滚动锚点(它不落库,没有 uuid 可用)。
    private static let streamingID = "streaming-preview"

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
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
