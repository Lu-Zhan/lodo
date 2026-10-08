import SwiftUI
import SwiftData
import LodoCore

/// AI 助手页里共享聊天室的导航目标(AI 页自己的 NavigationStack 上 push)。
enum ChatRoute: Hashable {
    case rooms
    case room(UUID)
}

// MARK: - 列表

/// 聊天室列表:可以建很多个。每个房间是一个 CloudKit 共享 zone,邀请/加入/销毁都走
/// `SharedTripSync`(见 `ChatRoom` 的注释)。
struct ChatRoomListView: View {
    @Binding var path: [ChatRoute]

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatRoom.lastMessageAt, order: .reverse) private var rooms: [ChatRoom]
    @State private var creating = false
    @State private var newTitle = ""
    @State private var pendingRemoval: ChatRoom?

    /// 同一个 uuid 可能短暂地有两行(去重在同步层做),列表上先去一遍。
    private var uniqueRooms: [ChatRoom] {
        var seen = Set<UUID>()
        return rooms.filter { seen.insert($0.uuid).inserted }
    }

    var body: some View {
        List {
            ForEach(uniqueRooms) { room in
                NavigationLink(value: ChatRoute.room(room.uuid)) {
                    ChatRoomRow(room: room)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingRemoval = room
                    } label: {
                        if room.isOwner {
                            Label("销毁", systemImage: "trash")
                        } else {
                            Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
        }
        .overlay {
            if uniqueRooms.isEmpty {
                ContentUnavailableView {
                    Label("还没有聊天室", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("建一个聊天室,邀请朋友一起商量行程、敲定细节。")
                } actions: {
                    Button("创建聊天室") { startCreating() }
                        .glassProminentButton()
                }
                .emptyStateFill()
            }
        }
        .pageTitle("聊天室")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startCreating()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("创建聊天室")
            }
        }
        .alert("创建聊天室", isPresented: $creating) {
            TextField("聊天室名字", text: $newTitle)
            Button("创建") { create() }
            Button("取消", role: .cancel) {}
        }
        .chatRoomRemovalDialog(room: $pendingRemoval) { room in
            SharedTripSync.shared.destroyOrLeave(room)
        }
    }

    private func startCreating() {
        newTitle = ""
        creating = true
    }

    private func create() {
        let base = String(localized: "新聊天室", bundle: .appLanguage())
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty
            ? ChatRoomPlan.defaultTitle(base: base, existing: rooms.map(\.title)) : trimmed
        guard let room = SharedTripSync.shared.createRoom(title: title) else { return }
        path.append(.room(room.uuid))
    }
}

/// 一行:名字、最近一条消息、时间、未读数。
private struct ChatRoomRow: View {
    let room: ChatRoom

    @Environment(\.modelContext) private var context
    @Query private var latest: [ChatRoomMessage]

    init(room: ChatRoom) {
        self.room = room
        let id = room.uuid
        var descriptor = FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == id },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        _latest = Query(descriptor)
    }

    private var unread: Int {
        let id = room.uuid
        let read = room.lastReadAt
        return (try? context.fetchCount(FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == id && !$0.fromMe && $0.createdAt > read }))) ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.shareRole == nil ? "bubble.left.and.bubble.right" : "person.2.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(room.title.isEmpty ? String(localized: "新聊天室", bundle: .appLanguage()) : room.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(room.lastMessageAt, format: .relative(presentation: .named))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                let count = unread
                if count > 0 {
                    Text("\(count)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        guard let message = latest.first else {
            return room.shareRole == nil
                ? String(localized: "还没连上 iCloud", bundle: .appLanguage())
                : String(localized: "还没有消息", bundle: .appLanguage())
        }
        if message.fromMe || message.kind == .system { return message.content }
        return message.senderName + ":" + message.content
    }
}

// MARK: - 聊天页

struct ChatRoomView: View {
    let roomUUID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lodoAccent) private var lodoAccent
    @Query private var rooms: [ChatRoom]
    @Query private var messages: [ChatRoomMessage]
    @State private var text = ""
    @State private var preparingShare = false
    @State private var errorText: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var pendingRemoval: ChatRoom?
    /// 「+」里点了哪一类内容;非 nil 时弹出对应的选择器(和 AI 对话的「引用」同一个)。
    @State private var sharePicker: AgentReferenceCategory?
    /// 正在为几张卡片取共享链接(取到再发,期间底部挂一行提示)。
    @State private var preparingCards = 0
    /// 这台设备的 AI 正在处理(那一行「我的 AI 正在…」提示的内容)。
    @State private var aiThought: String?
    @State private var aiTask: Task<Void, Never>?
    /// 第一次点亮 AI 开关时的说明(聊天内容会发给自己配置的 AI 服务商)。
    @State private var showsAINotice = false
    @AppStorage("chatAINoticeShown") private var aiNoticeShown = false
    @FocusState private var inputFocused: Bool
    #if DEBUG
    private static var demoSent = false
    #endif

    init(roomUUID: UUID) {
        self.roomUUID = roomUUID
        _rooms = Query(filter: #Predicate<ChatRoom> { $0.uuid == roomUUID })
        _messages = Query(filter: #Predicate<ChatRoomMessage> { $0.roomUUID == roomUUID },
                          sort: \.createdAt)
    }

    private var room: ChatRoom? { rooms.first }

    private var uniqueMessages: [ChatRoomMessage] {
        var seen = Set<UUID>()
        return messages.filter { seen.insert($0.uuid).inserted }
    }

    var body: some View {
        Group {
            if let room {
                content(room)
            } else {
                ContentUnavailableView("这个聊天室已经不在了", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("创建者销毁了聊天室,或者你已经退出。"))
            }
        }
    }

    private func content(_ room: ChatRoom) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 普通 VStack 而不是 LazyVStack,每条消息(连同它上面那行时间)是**一个**带 id
                // 的视图:同 AI 助手页的消息列表,scrollTo 才不会落空(Lazy 的还没建出来、
                // 或者 id 只挂在兄弟视图之一上时,新消息插进来列表不跟着滚到底,实测)。
                VStack(spacing: 8) {
                    if uniqueMessages.isEmpty {
                        emptyHint(room)
                    }
                    ForEach(Array(uniqueMessages.enumerated()), id: \.element.uuid) { index, message in
                        VStack(spacing: 8) {
                            if showsTimestamp(at: index) {
                                Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                            }
                            ChatMessageBubble(message: message, showsSender: showsSender(at: index))
                        }
                        .id(message.uuid)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: DesignMetrics.readableChatWidth)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            .softTopScrollEdgeTransition()
            .onAppear { scrollToBottom(proxy) }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification)) { _ in scrollToBottom(proxy) }
            #endif
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: uniqueMessages.count) { _, _ in
                scrollToBottom(proxy)
                markRead(room)
            }
            // 底部多出/收起一行提示(AI 在处理、报错)时输入区变高,最后一条会被压住一截。
            .onChange(of: aiThought == nil) { _, _ in scrollToBottom(proxy) }
            .onChange(of: errorText) { _, _ in scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                statusBanner(room)
                inputBar(room)
            }
            .frame(maxWidth: DesignMetrics.readableChatWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(room.title.isEmpty ? String(localized: "新聊天室", bundle: .appLanguage()) : room.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar(room) }
        .onAppear {
            markRead(room)
            #if DEBUG
            // 截图验证用:真发一次——打开 AI 开关、发一句话,看群聊模式下模型给什么。
            let args = ProcessInfo.processInfo.arguments
            if !Self.demoSent, let index = args.firstIndex(of: "--demo-chat-send"), index + 1 < args.count {
                Self.demoSent = true
                room.aiEnabled = true
                text = args[index + 1]
                send(room)
            }
            #endif
        }
        .alert("重命名聊天室", isPresented: $renaming) {
            TextField("聊天室名字", text: $newTitle)
            Button("保存") { rename(room) }
            Button("取消", role: .cancel) {}
        }
        .chatRoomRemovalDialog(room: $pendingRemoval) { room in
            SharedTripSync.shared.destroyOrLeave(room)
            dismiss()
        }
        .alert("让 AI 参与聊天?", isPresented: $showsAINotice) {
            Button("开启") {
                aiNoticeShown = true
                setAI(true, room: room)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后,你每发一条消息,这台设备都会把最近的聊天记录发给你配置的 AI 服务商来处理;AI 的回复房间里所有人都能看到。你的任务、记忆、资产、健康数据不会发出去。")
        }
        .sheet(item: $sharePicker) { category in
            AgentReferencePickerView(category: category, excluding: []) { picked in
                shareCards(picked, in: room)
            }
        }
    }

    /// 分享几条内容进聊天:内容快照现在就取(用户看到的就是发出去的那一版),
    /// 已经共享过的旅行/资产台账再取一下共享链接,取完按选择顺序发出。
    private func shareCards(_ references: [AgentReference], in room: ChatRoom) {
        let cards = references.map { reference in
            ChatCard(reference: reference, body: AgentReferenceRenderer.body(for: reference, in: context))
        }
        preparingCards += 1
        Task {
            defer { preparingCards -= 1 }
            for var card in cards {
                card.shareURL = await SharedTripSync.shared.existingShareURL(for: card.reference)?.absoluteString
                SharedTripSync.shared.send(card, in: room)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ room: ChatRoom) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    invite(room)
                } label: {
                    Label(room.isOwner ? LocalizedStringKey("邀请成员") : "查看成员", systemImage: "person.badge.plus")
                }
                .disabled(preparingShare)
                if room.isOwner {
                    Button {
                        newTitle = room.title
                        renaming = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    pendingRemoval = room
                } label: {
                    if room.isOwner {
                        Label("销毁聊天室", systemImage: "trash")
                    } else {
                        Label("退出聊天室", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多")
        }
    }

    private func emptyHint(_ room: ChatRoom) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(room.isOwner ? LocalizedStringKey("邀请朋友加入,开始聊天") : "还没有消息")
                .font(.headline)
            if room.isOwner {
                Button("邀请成员") { invite(room) }
                    .glassProminentButton()
                    .disabled(preparingShare)
            }
        }
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func statusBanner(_ room: ChatRoom) -> some View {
        if let thought = aiThought {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(thought)
                    .lineLimit(1)
                Button("停止") { aiTask?.cancel() }
                    .font(.footnote.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        } else if let message = errorText ?? (preparingShare
            ? String(localized: "正在建立共享…", bundle: .appLanguage())
            : preparingCards > 0 ? String(localized: "正在准备分享的内容…", bundle: .appLanguage()) : nil) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(errorText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(LodoColor.critical))
                .padding(.horizontal)
        } else if room.shareRole == nil {
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                Text("还没连上 iCloud,消息暂时只在这台设备上")
                Button("重试") { invite(room, presents: false) }
                    .font(.footnote.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
    }

    private func inputBar(_ room: ChatRoom) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            aiToggle(room)
            shareMenu
            textCapsule(room)
        }
        .glassGroup()
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// 输入栏最左边的「AI」:默认灰色(关),点亮后这台设备每发一条消息都请 AI 看一遍
    /// 聊天记录再回话。开关是每人各自的(`ChatRoom.aiEnabled` 不进共享)。
    private func aiToggle(_ room: ChatRoom) -> some View {
        Button {
            if room.aiEnabled {
                setAI(false, room: room)
            } else if aiNoticeShown {
                setAI(true, room: room)
            } else {
                showsAINotice = true
            }
        } label: {
            Text(verbatim: "AI")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(room.aiEnabled ? AnyShapeStyle(lodoAccent.onFill) : AnyShapeStyle(.secondary))
                .frame(width: DesignMetrics.aiInputHeight, height: DesignMetrics.aiInputHeight)
                .background {
                    if room.aiEnabled {
                        Circle().fill(lodoAccent.fill)
                    } else {
                        Color.clear.glassBackground(Circle())
                    }
                }
        }
        .pressable()
        .accessibilityLabel(room.aiEnabled ? "关闭 AI" : "开启 AI")
    }

    private func setAI(_ enabled: Bool, room: ChatRoom) {
        withAnimation(.lodoAware(.snappy(duration: 0.2))) { room.aiEnabled = enabled }
        try? context.save()
        if !enabled { aiTask?.cancel() }
    }

    /// 输入栏左边的「+」:把 app 里的内容(旅行、资产…)分享进聊天。和 AI 页输入栏的
    /// 「+」同一个外观(玻璃圆,不用 `.glassButton()`,理由见 `AgentView.attachButton`)。
    private var shareMenu: some View {
        Menu {
            Section("分享到聊天") {
                ForEach(AgentReferenceCategory.allCases) { category in
                    Button {
                        sharePicker = category
                    } label: {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: DesignMetrics.aiInputHeight, height: DesignMetrics.aiInputHeight)
                .glassBackground(Circle())
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .accessibilityLabel("分享内容")
    }

    private func textCapsule(_ room: ChatRoom) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("发消息", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.vertical, 6)
                .onSubmit { send(room) }
            Button {
                send(room)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(lodoAccent.onFill)
                    .frame(width: 36, height: 36)
                    .background(lodoAccent.fill, in: Circle())
                    .opacity(canSend ? 1 : 0.4)
            }
            .pressable()
            .disabled(!canSend)
            .hitTarget(visualSize: 36)
            .accessibilityLabel("发送")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: DesignMetrics.aiInputHeight)
        .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.composerRadius, style: .continuous))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = uniqueMessages.last else { return }
        // 等这一帧的输入区高度定下来再滚。
        DispatchQueue.main.async {
            withAnimation(.lodoAware(.snappy(duration: 0.25))) {
                proxy.scrollTo(last.uuid, anchor: .bottom)
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ room: ChatRoom) {
        guard canSend else { return }
        SharedTripSync.shared.send(text, in: room)
        text = ""
        if room.aiEnabled { runAI(room) }
    }

    /// 这台设备的 AI 看一遍聊天记录再回话;上一轮还在跑就先停掉(以最新那句为准)。
    private func runAI(_ room: ChatRoom) {
        aiTask?.cancel()
        errorText = nil
        aiThought = String(localized: "我的 AI 正在看聊天记录…", bundle: .appLanguage())
        aiTask = Task {
            defer { aiThought = nil }
            do {
                try await ChatRoomAI.respond(in: room, context: context) { thought in
                    aiThought = thought
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorText = error.localizedDescription
            }
        }
    }

    /// 和上一条隔了 10 分钟以上(或是第一条)就插一行时间。
    private func showsTimestamp(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let list = uniqueMessages
        return list[index].createdAt.timeIntervalSince(list[index - 1].createdAt) > 600
    }

    /// 别人连续发的几条只在第一条上面写名字。
    private func showsSender(at index: Int) -> Bool {
        let list = uniqueMessages
        let message = list[index]
        guard !message.fromMe, message.kind != .system else { return false }
        guard index > 0, !showsTimestamp(at: index) else { return true }
        let previous = list[index - 1]
        return previous.fromMe || previous.senderName != message.senderName || previous.kind != message.kind
    }

    private func markRead(_ room: ChatRoom) {
        guard let last = uniqueMessages.last?.createdAt, last > room.lastReadAt else { return }
        room.lastReadAt = last
        try? context.save()
    }

    private func rename(_ room: ChatRoom) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != room.title else { return }
        room.title = trimmed
        try? context.save()
    }

    /// 邀请成员 / 管理成员:第一次要先在 iCloud 上建 zone 和 share,要等几秒。
    /// presents = false 只是补建共享(「重试」),不弹系统界面。
    private func invite(_ room: ChatRoom, presents: Bool = true) {
        preparingShare = true
        errorText = nil
        Task {
            defer { preparingShare = false }
            do {
                let share = try await SharedTripSync.shared.prepareChatShare(for: room)
                if presents { CloudSharingPresenter.present(share: share, room: room) }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - 气泡

private struct ChatMessageBubble: View {
    let message: ChatRoomMessage
    let showsSender: Bool

    @Environment(\.lodoAccent) private var lodoAccent

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.content)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .text, .ai, .card:
            HStack(alignment: .bottom) {
                if message.fromMe { Spacer(minLength: 48) }
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                    if showsSender || message.kind == .ai {
                        senderLine
                    }
                    if message.kind == .card, let card = message.card {
                        ChatCardView(card: card)
                    } else {
                        bubble
                    }
                    if message.kind == .ai, let proposal = message.proposal {
                        ChatProposalView(messageID: message.uuid, proposal: proposal,
                                         roomUUID: message.roomUUID)
                    }
                }
                if !message.fromMe { Spacer(minLength: 48) }
            }
        }
    }

    @ViewBuilder
    private var senderLine: some View {
        if message.kind == .ai {
            Label(message.fromMe
                  ? String(localized: "我的 AI", bundle: .appLanguage())
                  : String(localized: "\(message.senderName)的 AI", bundle: .appLanguage()),
                  systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(message.senderName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        let text = Text(message.content)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        if message.kind == .ai {
            // AI 的回复和「我的 AI 助手」那边同一种玻璃卡片。
            text.agentCard(padding: 0, hugsContent: true)
        } else if message.fromMe {
            text
                .foregroundStyle(lodoAccent.onFill)
                .background(lodoAccent.fill,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        } else {
            text
                .background(.fill.tertiary,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        }
    }
}

// MARK: - 销毁 / 退出确认

private extension View {
    /// 创建者「销毁」(所有人的这个房间连同消息一起删掉)/ 成员「退出」。
    func chatRoomRemovalDialog(room: Binding<ChatRoom?>,
                               perform: @escaping (ChatRoom) -> Void) -> some View {
        let isOwner = room.wrappedValue?.isOwner ?? true
        return confirmationDialog(
            isOwner ? LocalizedStringKey("销毁这个聊天室?") : "退出这个聊天室?",
            isPresented: Binding(get: { room.wrappedValue != nil },
                                 set: { if !$0 { room.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button(isOwner ? LocalizedStringKey("销毁") : "退出", role: .destructive) {
                if let target = room.wrappedValue { perform(target) }
                room.wrappedValue = nil
            }
        } message: {
            Text(isOwner
                 ? LocalizedStringKey("所有成员的这个聊天室和全部消息都会被删除,不可恢复。")
                 : "这台设备上的聊天记录会被删除,之后要有人重新邀请才能回来。")
        }
    }
}

// MARK: - 内容卡片

/// 聊天里分享的内容卡片。按钮按"这台设备上有没有这份内容"分:
/// 有 → 「打开」进到那一页;没有但它是一份共享(带链接)→ 「加入共享」;
/// 都没有 → 只能「查看内容」看分享那一刻的快照。
private struct ChatCardView: View {
    let card: ChatCard

    @Environment(\.modelContext) private var context
    @Environment(\.itemNavigator) private var navigator
    @Environment(\.openURL) private var openURL
    @State private var showsBody = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.reference.kind.symbol)
                    .foregroundStyle(.tint)
                Text(card.reference.kind.displayTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if card.shareURL != nil {
                    Label("共享中", systemImage: "person.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(card.reference.title)
                .font(.headline)
                .lineLimit(2)
            let preview = card.preview()
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                if let destination = localDestination {
                    Button("打开") { navigator?.open(destination) }
                        .buttonStyle(.borderedProminent)
                } else if let raw = card.shareURL, let url = URL(string: raw) {
                    Button("加入共享") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("查看内容") { showsBody = true }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.fill.tertiary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        .sheet(isPresented: $showsBody) {
            ChatCardBodySheet(card: card)
        }
    }

    /// 这台设备上有这份内容时去哪儿打开它。只认能落到具体页面的几类;
    /// 任务、人脉、菜单这些没有对应的跳转目标,只给「查看内容」。
    private var localDestination: AppDestination? {
        guard navigator != nil else { return nil }
        let id = card.reference.id
        switch card.reference.kind {
        case .trip:
            return exists(FetchDescriptor<TravelTrip>(predicate: #Predicate { $0.uuid == id })) ? .trip(id) : nil
        case .asset:
            return exists(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == id })) ? .assets : nil
        case .finance:
            return exists(FetchDescriptor<FinanceEntry>(predicate: #Predicate { $0.uuid == id })) ? .assets : nil
        case .countdown:
            return exists(FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.uuid == id })) ? .countdown : nil
        case .news:
            return exists(FetchDescriptor<NewsArticle>(predicate: #Predicate { $0.uuid == id })) ? .news : nil
        case .task, .contact, .menu:
            return nil
        }
    }

    private func exists<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Bool {
        ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}

/// 卡片的完整快照。
private struct ChatCardBodySheet: View {
    let card: ChatCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(card.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(card.reference.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

extension AgentReferenceKind {
    /// 界面上的种类名(随应用语言)。`promptLabel` 是喂给模型的,别混用。
    var displayTitle: LocalizedStringKey {
        switch self {
        case .task: return "任务"
        case .countdown: return "倒数日"
        case .trip: return "旅行"
        case .asset: return "资产"
        case .finance: return "收支"
        case .contact: return "人脉"
        case .menu: return "菜单"
        case .news: return "新闻"
        }
    }
}

// MARK: - AI 提案

/// 这台设备上已经写入过哪些提案(按消息 uuid + 哪一部分)。消息本身只追加、不能改,
/// 写入状态记在本机;写入的同时往房间里发一条系统消息,其他成员看得到"谁写了什么"。
enum ChatProposalLedger {
    enum Part: String { case plan, edit, tasks, countdowns }
    private static let key = "chatAppliedProposals"

    static func isApplied(_ message: UUID, _ part: Part) -> Bool {
        (UserDefaults.standard.dictionary(forKey: key)?[message.uuidString] as? [String])?
            .contains(part.rawValue) ?? false
    }

    static func markApplied(_ message: UUID, _ part: Part) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        var parts = all[message.uuidString] as? [String] ?? []
        if !parts.contains(part.rawValue) { parts.append(part.rawValue) }
        all[message.uuidString] = parts
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// AI 回复下面那张"待确认"卡片:规划 / 行程调整 / 任务 / 倒数日,各自一颗写入按钮。
/// 谁点就写进谁的 lodo;写进共享旅行时其他成员那边随共享同步一起变。
private struct ChatProposalView: View {
    let messageID: UUID
    let proposal: ChatProposal
    let roomUUID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.itemNavigator) private var navigator
    /// 写入后让按钮刷新(写入状态存在 UserDefaults,SwiftUI 看不见它变)。
    @State private var revision = 0
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = proposal.tripPlan { planSection(plan) }
            if let edit = proposal.tripEdit { editSection(edit) }
            if !proposal.tasks.isEmpty { tasksSection }
            if !proposal.countdowns.isEmpty { countdownSection }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.fill.tertiary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        .id(revision)
    }

    // MARK: 规划

    private func planSection(_ plan: TripPlanProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("行程规划「\(plan.tripTitle)」")
            } icon: {
                Image(systemName: "map")
            }
            .font(.subheadline.weight(.semibold))
            Text(plan.startDate.formatted(Self.dayFormat) + " – "
                 + plan.endDate.formatted(Self.dayFormat)
                 + " · " + String(localized: "\(plan.items.count) 项安排", bundle: .appLanguage()))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(plan.items.prefix(4).map(\.title).joined(separator: "、") + (plan.items.count > 4 ? "…" : ""))
                .font(.footnote)
                .lineLimit(2)
            if ChatProposalLedger.isApplied(messageID, .plan) {
                appliedRow(open: existingTrip(named: plan.tripTitle).map { AppDestination.trip($0) })
            } else {
                Button("写入行程") { applyPlan(plan) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func applyPlan(_ plan: TripPlanProposal) {
        let applied = TravelStore.applyPlan(plan, context: context)
        ChatProposalLedger.markApplied(messageID, .plan)
        announce { who in String(localized: "\(who)把行程写进了旅行「\(applied.tripTitle)」", bundle: .appLanguage()) }
    }

    // MARK: 调整

    private func editSection(_ edit: TripEdit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("调整旅行「\(edit.tripTitle)」")
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .font(.subheadline.weight(.semibold))
            Text(String(localized: "删 \(edit.removeIDs.count) 项 · 加 \(edit.additions.count) 项 · 改 \(edit.updates.count) 项",
                        bundle: .appLanguage()))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if ChatProposalLedger.isApplied(messageID, .edit) {
                appliedRow(open: existingTrip(named: edit.tripTitle).map { AppDestination.trip($0) })
            } else {
                Button("调整行程") { applyEdit(edit) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func applyEdit(_ edit: TripEdit) {
        guard let record = TravelStore.applyEdit(edit, context: context) else {
            note = String(localized: "这台设备上没有这趟旅行,先加入它的共享再调整。", bundle: .appLanguage())
            return
        }
        guard record.hasChanges else {
            note = String(localized: "没有可以改的行程项(航班和带附件的不改)。", bundle: .appLanguage())
            return
        }
        ChatProposalLedger.markApplied(messageID, .edit)
        announce { who in String(localized: "\(who)调整了旅行「\(record.tripTitle)」", bundle: .appLanguage()) }
    }

    // MARK: 任务 / 倒数日

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("任务", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(proposal.tasks.enumerated()), id: \.offset) { _, task in
                Text("· " + task.title + "  " + LocalizedContent.taskCaption(task))
                    .font(.footnote)
                    .lineLimit(1)
            }
            if ChatProposalLedger.isApplied(messageID, .tasks) {
                appliedRow(open: nil)
            } else {
                Button("加到我的任务") { applyTasks() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func applyTasks() {
        for task in proposal.tasks {
            TaskActions.create(task, context: context)
        }
        WidgetBridge.sync(context: context)
        CalendarSync.sync(context: context)
        ChatProposalLedger.markApplied(messageID, .tasks)
        revision += 1
    }

    private var countdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("倒数日", systemImage: "hourglass")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(proposal.countdowns.enumerated()), id: \.offset) { _, draft in
                Text("· " + draft.title + "  " + draft.start.formatted(Self.dayFormat))
                    .font(.footnote)
                    .lineLimit(1)
            }
            if ChatProposalLedger.isApplied(messageID, .countdowns) {
                appliedRow(open: .countdown)
            } else {
                Button("加到我的倒数日") { applyCountdowns() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func applyCountdowns() {
        _ = CountdownStore.apply(proposal.countdowns.map { CountdownOp.create($0) }, context: context)
        ChatProposalLedger.markApplied(messageID, .countdowns)
        revision += 1
    }

    // MARK: 共用

    /// 日期按应用内语言出(`.formatted` 默认跟系统语言)。
    private static var dayFormat: Date.FormatStyle {
        Date.FormatStyle.dateTime.month().day().locale(AppSettings.language.locale)
    }

    private func appliedRow(open destination: AppDestination?) -> some View {
        HStack(spacing: 8) {
            Label("已写入", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(LodoColor.positive)
            if let destination, let navigator {
                Button("打开") { navigator.open(destination) }
                    .font(.footnote)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func existingTrip(named title: String) -> UUID? {
        TravelStore.trips(in: context).first {
            $0.title.trimmingCharacters(in: .whitespaces).lowercased()
                == title.trimmingCharacters(in: .whitespaces).lowercased()
        }?.uuid
    }

    /// 写进行程这类会影响别人的,在房间里留一句话。
    private func announce(_ sentence: (String) -> String) {
        revision += 1
        let id = roomUUID
        guard let room = try? context.fetch(FetchDescriptor<ChatRoom>(
            predicate: #Predicate { $0.uuid == id })).first else { return }
        let me = SharedTripSync.myDisplayName
        let who = me.isEmpty ? String(localized: "一位成员", bundle: .appLanguage()) : me
        SharedTripSync.shared.send(sentence(who), kind: .system, in: room)
    }
}
