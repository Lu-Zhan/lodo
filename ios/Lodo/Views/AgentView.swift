import SwiftUI
import SwiftData
import PhotosUI
import LodoCore

/// 右下角"添加"按钮触发的 AI 对话页:持久保存多个 thread(左上角切换/新建),
/// 每轮请求真的带上前几轮对话历史;右下角语音、左侧 + 号传照片/文件。
/// 单条新建/修改叠一个 TaskEditView 在本页上面("表单即确认"这个体验保留),
/// 保存后往当前 thread 追加一条结果消息,不关掉聊天页。
struct AgentView: View {
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]

    @State private var currentThreadUUID: UUID?
    /// ReAct 循环中间步骤的轻量提示(如"正在查记忆…");不落库,循环一结束就清空。
    @State private var thinkingText: String?

    @State private var text: String
    @State private var busy = false
    /// 发送中的请求;busy 时发送按钮变成取消,点了就 cancel 这个 Task。
    @State private var sendTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 打开页面默认唤起键盘,方便直接打字;语音改成手动点麦克风图标触发。
    @FocusState private var isInputFocused: Bool
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    /// 窄屏时表示抽屉是否展开,宽屏时表示常驻侧栏是否可见;两种布局共用同一个开关。
    @State private var showThreads = false
    /// 窄屏抽屉横向拖拽关闭手势的实时位移。
    @State private var sidebarDragOffset: CGFloat = 0
    /// 本次拖拽的起点 + 归属判定;起点变了就说明换了一次新拖拽,重新判定。
    /// 不只靠 onEnded 复位:手势被系统中断时 onEnded 不一定会来,只靠它复位会让
    /// 下一次右滑整个失灵。
    @State private var dragSession: (start: CGPoint, intent: DragIntent)?

    /// 整页任意位置都能右滑唤出侧栏,所以这个手势和消息列表的纵向滚动是并行挂着的
    /// (simultaneousGesture)。哪一方接管这次拖拽在**第一帧**就定死、之后不再改判:
    /// 否则先纵向滚一段、中途拐个横向,侧栏会毫无预兆地跳出来。
    private enum DragIntent { case sidebar, ignored }
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var showFileImporter = false
    @State private var showMemoryPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var formTarget: FormTarget?

    init(prefill: String? = nil,
         submit: @escaping (
            String, UUID, [(role: String, content: String)], @escaping (String) -> Void
         ) async throws -> AgentReply,
         onConfirm: @escaping (UUID) -> Void,
         onUndo: @escaping (UUID) -> AgentReply,
         saveTask: @escaping (TaskItem?, ParsedTask) -> Void) {
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

    /// 标题栏正标题:当前对话的标题(首轮消息后换成 AI 总结的那版);还没发过
    /// 消息的空 thread 用和侧栏列表一致的"新对话"占位。
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
            Group {
                if horizontalSizeClass == .regular {
                    regularLayout
                } else {
                    compactLayout
                }
            }
            // 整页按屏幕物理底边布局,不给 home indicator 预留一条死白边——
            // 输入栏那三个玻璃胶囊因此贴到真正的屏幕底部,聊天内容也一路铺满。
            // 只忽略 .container(不能用 .all):键盘安全区仍然生效,弹键盘时
            // 输入栏照常被顶上去。
            .ignoresSafeArea(.container, edges: .bottom)
            // 抽屉推开时连标题一起清空:principal 那项被撤掉后,navigationTitle
            // 会顶上来接着显示,和侧栏自己的标题挤在一起。
            .navigationTitle(hidesToolbarChrome ? "" : threadTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // 自定义 principal:标题栏显示当前对话的总结标题(首轮消息后由
                // summarizeThreadTitle 生成,在此之前是原话截断);标题下加一行
                // 当前 AI 模式(服务商/思考强度/联网搜索),不然用户在对话里完全
                // 看不出现在到底是哪个服务商、思考开没开、能不能联网搜索——
                // 这些都要跳回设置页才看得到。
                if !hidesToolbarChrome {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(threadTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Text(aiModeSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .navigation) {
                        Button {
                            isInputFocused = false
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                showThreads.toggle()
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                        .accessibilityLabel("对话列表")
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
            }
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
            .onDisappear {
                speech.stop()
                discardUnsentAttachments()
            }
            .task {
                ensureThreadExists()
                isInputFocused = true
                if horizontalSizeClass == .regular { showThreads = true }
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
                // 截图验证用:直接推开侧栏(simctl 没法点汉堡也没法滑手势),
                // 顺带塞几条历史对话把列表填出来。
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-sidebar") {
                    seedDemoThreads()
                    isInputFocused = false
                    showThreads = true
                }
                #endif
            }
        }
        #if os(macOS)
        // 宽屏(macOS 恒为 .regular)默认展开常驻侧栏,460pt 老尺寸减去侧栏宽度后
        // 聊天区太窄,放宽到能同时容纳侧栏 + 舒适聊天区。iOS 上 agent 恒走
        // fullScreenCover(见 TodoListView.swift),没有 sheet 尺寸/手势可调,
        // 这里不需要 iOS 分支。
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        #endif
    }

    // MARK: - 左侧对话列表侧栏(窄屏抽屉 / 宽屏常驻列)

    /// 消息列表 + 输入栏这一整块;两种布局都直接复用,不重复接线。
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
                                onExamplePrompt: { send(overrideText: $0) })
                .id(thread.uuid)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        thinkingRow
                        attachmentChipsRow
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

    private var sidebarPanel: some View {
        AgentThreadListView(currentThreadUUID: $currentThreadUUID) {
            if horizontalSizeClass != .regular { closeSidebar() }
        }
        .frame(maxHeight: .infinity)
        // 日间用纯背景色而不是磨砂材质:材质会透出一块带灰的底,和参考图里
        // "面板和被推开的卡几乎同色、只靠投影分层"的观感对不上。用语义的
        // BackgroundStyle 而不是 UIKit 专有的 systemBackground,iOS/macOS 通吃。
        // 夜间仍用材质:近黑背景上投影几乎看不见,面板再跟着变纯黑就和被推开的
        // 那张卡糊成一片,分不出边界了(和下面 sidebarScrim 是同一个理由)。
        .background(colorScheme == .dark
                    ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.background))
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showThreads = false }
    }

    /// 窄屏抽屉推开时整组工具栏项(汉堡/标题/关闭)直接撤掉:工具栏挂在
    /// NavigationStack 上、不会跟着 chatColumn 平移,留着的话汉堡会浮在侧栏上面,
    /// 标题那个 "Lodo" 还会和侧栏自己的 "Lodo" 标题重复。这里必须是"移除"而不是
    /// 给按钮加 .opacity(0)——iOS 26 工具栏按钮的 Liquid Glass 底是系统画的,
    /// 不跟着 label 的透明度走,只调透明度会在顶上留下两个空玻璃圆圈。
    /// 判据是 sidebarProgress 而不是 showThreads:拖到一半时汉堡同样会浮在已经
    /// 露出来的那截侧栏上面,所以拖拽一起手就得撤掉,不能等松手落定。
    /// 宽屏常驻列不推开内容,工具栏照常显示。
    private var hidesToolbarChrome: Bool {
        horizontalSizeClass != .regular && sidebarProgress > 0
    }

    /// 侧栏推开时盖在聊天卡上的那层遮罩:日间照参考图压一层半透明**白**——内容
    /// 被洗淡、卡片比侧栏更白,"这块暂时不能操作"的意思出来了,又不会像灰黑遮罩
    /// 那样把整张卡压成一块灰框;夜间白色反而刺眼,仍用原来的半透明黑压暗。
    /// 这层遮罩同时是"点一下关闭"和展开后"左滑收回"的手势承载层,不能省掉。
    private var sidebarScrim: some View {
        (colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
    }

    /// 0 = 完全收起,1 = 完全展开;拖拽期间取中间值,松手后回到 0/1。
    /// 抽屉的所有视觉量(推移/缩放/圆角/变暗)都从这一个进度插值出来,
    /// 开合两个方向才能同样跟手。
    private var sidebarProgress: CGFloat {
        let base: CGFloat = showThreads ? 1 : 0
        return min(1, max(0, base + sidebarDragOffset / DesignMetrics.sidebarWidth))
    }

    /// 松手后按"已拖过 30% 宽 或 甩动预测能到 50% 宽"判定落到哪一端,开合对称。
    private func settleSidebar(_ value: DragGesture.Value, opening: Bool) {
        let width = DesignMetrics.sidebarWidth
        let sign: CGFloat = opening ? 1 : -1
        let passed = value.translation.width * sign > width * 0.3
            || value.predictedEndTranslation.width * sign > width * 0.5
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            sidebarDragOffset = 0
            if passed { showThreads = opening }
        }
    }

    /// 整页右滑唤出 / 右滑收回的手势本体,聊天内容和变暗遮罩上各挂一份。
    private func sidebarDrag() -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let intent: DragIntent
                if let session = dragSession, session.start == value.startLocation {
                    intent = session.intent
                } else {
                    // 一次拖拽的第一帧:横向为主 + 方向对(收起时向右开、展开时
                    // 向左关)才接管;纵向滚动和反方向的横滑一律让给底下的视图。
                    let horizontal = abs(value.translation.width) > abs(value.translation.height)
                    let rightDirection = showThreads
                        ? value.translation.width < 0 : value.translation.width > 0
                    intent = (horizontal && rightDirection) ? .sidebar : .ignored
                    dragSession = (value.startLocation, intent)
                }
                guard intent == .sidebar else { return }
                sidebarDragOffset = showThreads
                    ? min(0, value.translation.width) : max(0, value.translation.width)
            }
            .onEnded { value in
                let wasSidebar = dragSession?.intent == .sidebar
                dragSession = nil
                if wasSidebar { settleSidebar(value, opening: !showThreads) }
            }
    }

    /// 窄屏(iPhone、紧凑宽度 iPad):侧栏从左滑入,主内容整体推移变暗。
    /// 开合都能手势拖,而且**整页任意位置**右滑都算(不只左边缘那条窄带):
    /// 收起时在聊天区右滑唤出,展开后在变暗的聊天区(或面板上)左滑收回。
    /// (早先只做关闭手势是因为那时 AgentView 还是 .sheet、会和下拉关闭抢手势;
    /// 现在改成了 fullScreenCover,没有下拉关闭手势,可以放心加开启手势。)
    private var compactLayout: some View {
        ZStack(alignment: .leading) {
            // 侧栏排在前面 = 画在底下:聊天卡盖在它上面,卡片的投影才能落到侧栏上
            // (参考图就是这个层次)。面板自己因此不带投影。
            // 面板常驻渲染,靠 offset 推到屏幕外表示收起——这样拖拽中间态才有东西
            // 可跟手(条件渲染 + transition 做不到跟手,只能播一段固定动画)。
            sidebarPanel
                .frame(width: DesignMetrics.sidebarWidth)
                .offset(x: -(1 - sidebarProgress) * DesignMetrics.sidebarWidth)
                .gesture(
                    DragGesture()
                        .onChanged { sidebarDragOffset = min(0, $0.translation.width) }
                        .onEnded { settleSidebar($0, opening: false) }
                )

            // 顺序要紧:先叠遮罩、再 clipShape 圆角,最后才缩放+推移。
            // clipShape 必须排在 offset 前面——offset 是布局中立的渲染位移,排在它
            // 后面的 clipShape 仍按"没被推移的原始 frame"裁切,圆角会落在被侧栏盖住
            // 的屏幕左边缘外,推出来的那张卡看上去就是一条笔直的硬边。遮罩也放进
            // 裁切范围内,不然方角的遮罩会盖住卡片的圆角。
            chatColumn
                // 收起时手势挂在聊天内容上(和消息列表的滚动并行)。
                .simultaneousGesture(showThreads ? nil : sidebarDrag())
                // allowsHitTesting 只罩聊天内容本身,不能挂到遮罩外面去——遮罩要
                // 继续吃"点一下关闭"和"左滑收回"这两个手势。
                .allowsHitTesting(!showThreads)
                .overlay {
                    if sidebarProgress > 0 {
                        sidebarScrim
                            .opacity(sidebarProgress)
                            .contentShape(Rectangle())
                            .onTapGesture { closeSidebar() }
                            .gesture(sidebarDrag())
                    }
                }
                // 圆角不再按 progress 插值:参考图里被推开的那张卡从一开始就是整块
                // 手机尺寸的圆角。完全收起时才给 0,免得静止满屏时裁出一圈和真机
                // 屏幕遮罩对不上的角;刚离开 0 那一瞬间卡还基本满屏,44pt 的圆角落在
                // 屏幕自身的遮罩里面,看不出跳变。
                .clipShape(RoundedRectangle(
                    cornerRadius: sidebarProgress > 0 ? DesignMetrics.deviceCornerRadius : 0,
                    style: .continuous))
                .shadow(color: .black.opacity(0.18 * sidebarProgress), radius: 14, x: -3)
                // 只平移不缩放:聊天卡保持原大小整块推出去(右侧推出屏幕外),
                // 缩小那版看着像整页被"捏小",不是参考图里那种一张卡被推开的感觉。
                .offset(x: sidebarProgress * DesignMetrics.sidebarWidth)
        }
        // 只对 showThreads 挂动画:拖拽中 sidebarDragOffset 的变化要 1:1 跟手,
        // 不能被动画平滑掉(松手归位那下由 settleSidebar 里的 withAnimation 负责)。
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showThreads)
    }

    /// 宽屏(iPad 横屏、macOS):侧栏常驻展示,同一个汉堡按钮收起/展开,不做推移动画。
    private var regularLayout: some View {
        HStack(spacing: 0) {
            if showThreads {
                sidebarPanel
                    .frame(width: DesignMetrics.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            chatColumn
        }
        .animation(.easeInOut(duration: 0.2), value: showThreads)
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

    /// 参考 iMessage 的输入栏,三个独立玻璃控件一字排开:+ 号圆按钮、文本框
    /// 胶囊、麦克风/发送圆按钮。没在打字/正在录音时最右是麦克风(点了直接
    /// 开始/停止录音);一旦有内容待发送(打字或已选好附件),同一个槽位换成
    /// 蓝色发送按钮——是"麦克风 ↔ 独立发送按钮"互斥切换,不是文本框内嵌图标。
    /// iOS/macOS 26+ 用 `GlassEffectContainer` 把三个控件分组——这是苹果
    /// Liquid Glass 官方推荐的写法,组内形状会正确地互相感知、按需融合/晕开,
    /// 比三个各自独立的 `.glassEffect()` 观感更接近系统输入栏;旧系统没有
    /// 这个容器 API,直接退化成不分组的普通排布(各控件仍有自己的
    /// glassBackground 回退样式)。
    @ViewBuilder
    private var inputBar: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { inputBarRow }
        } else {
            inputBarRow
        }
    }

    private var inputBarRow: some View {
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

            TextField("说点什么…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { send() }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .glassBackground(Capsule())

            if showsInlineMic {
                inlineMicButton
            } else {
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                .frame(width: 36, height: 36)
                .glassBackground(Circle())
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
                .font(.system(size: busy ? 15 : 17, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .glassProminentButton()
        .buttonBorderShape(.circle)
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
        text = ""

        var userMessage: AgentMessage?
        if !hidesUserBubble {
            let message = AgentMessage(
                threadUUID: thread.uuid, role: .user, content: trimmed,
                attachmentMemoryUUIDs: attachments.compactMap(\.memoryUUID))
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
        case .ask(let questions): return questions.first?.question ?? ""
        case .answer(let text, _): return text
        case .suggestMemorize(let text): return text
        case .memorized: return "已收藏一条记忆"
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
        if ProcessInfo.processInfo.arguments.contains("--demo-agent-memory-result") {
            context.insert(AgentMessage(threadUUID: thread.uuid, role: .user, content: "记住wifi密码是8888"))
            let item = MemoryPipeline.saveText("wifi密码是8888", context: context)
            appendAssistant(thread: thread, kind: .memoryResult, content: "已收藏",
                            resultMemoryUUID: item?.uuid)
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
            // 侧栏现在是内联 body 内容(不再是挂在工具栏按钮上的 popover),
            // 但当帧展开偶发还没吃到新插入的 thread 数据,延后一点再展开更稳。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                showThreads = true
            }
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

    @Query private var messages: [AgentMessage]

    init(thread: AgentThread, onConfirmAction: @escaping (AgentMessage, Bool) -> Void,
         onUndo: @escaping () -> Void, onMemorizeSuggestion: @escaping (AgentMessage) -> Void,
         onTaskProposalConfirm: @escaping (AgentMessage) -> Void,
         onTaskProposalCancel: @escaping (AgentMessage) -> Void,
         onTaskProposalTap: @escaping (AgentMessage) -> Void,
         onAskSubmit: @escaping (AgentMessage, [[String]]) -> Void,
         onAskCancel: @escaping (AgentMessage) -> Void,
         onExamplePrompt: @escaping (String) -> Void) {
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
                            onAskCancel: { onAskCancel(message) })
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
