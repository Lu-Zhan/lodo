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
    @FocusState private var inputFocused: Bool

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
                LazyVStack(spacing: 8) {
                    if uniqueMessages.isEmpty {
                        emptyHint(room)
                    }
                    ForEach(Array(uniqueMessages.enumerated()), id: \.element.uuid) { index, message in
                        if showsTimestamp(at: index) {
                            Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ChatMessageBubble(message: message, showsSender: showsSender(at: index))
                            .id(message.uuid)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: DesignMetrics.readableChatWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: uniqueMessages.count) { _, _ in
                if let last = uniqueMessages.last {
                    withAnimation(.lodoAware(.snappy(duration: 0.25))) {
                        proxy.scrollTo(last.uuid, anchor: .bottom)
                    }
                }
                markRead(room)
            }
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
        .onAppear { markRead(room) }
        .alert("重命名聊天室", isPresented: $renaming) {
            TextField("聊天室名字", text: $newTitle)
            Button("保存") { rename(room) }
            Button("取消", role: .cancel) {}
        }
        .chatRoomRemovalDialog(room: $pendingRemoval) { room in
            SharedTripSync.shared.destroyOrLeave(room)
            dismiss()
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
        if let message = errorText ?? (preparingShare
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
            shareMenu
            textCapsule(room)
        }
        .glassGroup()
        .padding(.horizontal)
        .padding(.bottom, 12)
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

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ room: ChatRoom) {
        guard canSend else { return }
        SharedTripSync.shared.send(text, in: room)
        text = ""
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
                    if showsSender || (message.kind == .ai && !message.fromMe) {
                        senderLine
                    }
                    if message.kind == .card, let card = message.card {
                        ChatCardView(card: card)
                    } else {
                        bubble
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
