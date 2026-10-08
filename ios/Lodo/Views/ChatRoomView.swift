import SwiftUI
import SwiftData
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import LodoCore

// MARK: - 聊天页

/// 一个共享聊天室。外层管房间本身、输入栏、AI 和各种弹窗;消息列表在 `ChatTimeline`
/// 里按窗口分页取(同 AI 助手页:倒序取最近 N 条,顶上「载入更早的消息」加一页)。
struct ChatRoomView: View {
    let roomUUID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lodoAccent) private var lodoAccent
    @Query private var rooms: [ChatRoom]

    /// 一次取多少条消息;「载入更早的消息」每次加一页。
    static let pageSize = 60
    @State private var window = ChatRoomView.pageSize

    @State private var text = ""
    @State private var preparingShare = false
    @State private var errorText: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var pendingRemoval: ChatRoom?
    /// 「+」里点了哪一类内容;非 nil 时弹出对应的选择器(和 AI 对话的「引用」同一个)。
    @State private var sharePicker: AgentReferenceCategory?
    @State private var showsPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsFileImporter = false
    /// 正在准备几件要发的东西(取共享链接、读图片),期间底部挂一行提示。
    @State private var preparing = 0
    /// 这台设备的 AI 正在处理(那一行「我的 AI 正在…」提示的内容)。
    @State private var aiThought: String?
    @State private var aiTask: Task<Void, Never>?
    /// 第一次点亮 AI 开关时的说明(聊天内容会发给自己配置的 AI 服务商)。
    @State private var showsAINotice = false
    @AppStorage("chatAINoticeShown") private var aiNoticeShown = false
    /// 房间里已经接受邀请的人数(含自己),判断提问是不是大家都答完了。取不到为 nil。
    @State private var memberCount: Int?
    /// 点「载入更早的消息」之前最上面那一条:时间线重建后停在它这儿,不跳回底部。
    @State private var loadAnchor: UUID?
    /// 待回答的提问卡滚出可视范围时,输入栏上方那颗「问题:… ›」(时间线报上来)。
    @State private var offscreenAsk: ChatPendingAsk?
    /// 让时间线滚到某一条(点「问题」那颗按钮)。
    @State private var scrollRequest: UUID?
    /// 输入区高度变了(多出/收起一行提示),时间线贴回底部。
    @State private var bottomTick = 0
    @FocusState private var inputFocused: Bool
    #if DEBUG
    private static var demoSent = false
    #endif

    init(roomUUID: UUID) {
        self.roomUUID = roomUUID
        _rooms = Query(filter: #Predicate<ChatRoom> { $0.uuid == roomUUID })
    }

    private var room: ChatRoom? { rooms.first }

    private var coordinator: ChatAskCoordinator { .shared }

    var body: some View {
        Group {
            if let room {
                content(room)
            } else if SharedTripSync.shared.isRoomLoading(roomUUID) {
                // 接受了邀请、房间记录还没拉下来(网络慢、首次拉取失败):不是"已经不在了"。
                ContentUnavailableView {
                    Label("正在加载聊天室…", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("刚加入的聊天室要从 iCloud 拉下来,网络不好时会慢一些。")
                } actions: {
                    Button("重试") { Task { await SharedTripSync.shared.reloadRoom(roomUUID) } }
                        .glassButton()
                }
                .task { await SharedTripSync.shared.reloadRoom(roomUUID) }
            } else {
                ContentUnavailableView("这个聊天室已经不在了", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("创建者销毁了聊天室,或者你已经退出。"))
            }
        }
    }

    private func content(_ room: ChatRoom) -> some View {
        ChatTimeline(
            roomUUID: roomUUID, window: window, anchor: loadAnchor, isOwner: room.isOwner,
            memberCount: memberCount,
            scrollRequest: $scrollRequest, offscreenAsk: $offscreenAsk, bottomTick: bottomTick,
            onLoadEarlier: { oldest in
                loadAnchor = oldest
                window += Self.pageSize
            },
            onInvite: { invite(room) },
            onAnswer: { answers, ask in
                SharedTripSync.shared.sendAnswer(answers, to: ask, in: room)
                // 我可能是最后一个答的。
                coordinator.check(roomUUID: roomUUID)
            },
            onSummarize: { ask in
                guard ask.fromMe else { return }
                coordinator.summarize(askID: ask.uuid, in: room)
            },
            onRecall: { message in SharedTripSync.shared.recall(message, in: room) },
            onNewMessages: { markRead(room) })
            // 换一次窗口大小就要重建 @Query(同 AI 助手页 .id(historyWindow) 的写法)。
            .id(window)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if let ask = offscreenAsk { askPill(ask) }
                    statusBanner(room)
                    inputBar(room)
                }
                .frame(maxWidth: DesignMetrics.readableChatWidth)
                .frame(maxWidth: .infinity)
                .animation(.lodoAware(.snappy(duration: 0.2)), value: offscreenAsk)
            }
            .onChange(of: aiThought == nil) { _, _ in bottomTick += 1 }
            .onChange(of: errorText) { _, _ in bottomTick += 1 }
            .onChange(of: offscreenAsk == nil) { _, _ in bottomTick += 1 }
            .navigationTitle(room.title.isEmpty ? String(localized: "新聊天室", bundle: .appLanguage()) : room.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar(room) }
            .onDisappear {
                if SharedTripSync.shared.visibleRoom == roomUUID { SharedTripSync.shared.visibleRoom = nil }
            }
            .onAppear {
                SharedTripSync.shared.visibleRoom = roomUUID
                markRead(room)
                // 不在这页时大家答完了:进来时补一次检查。
                coordinator.check(roomUUID: roomUUID)
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
            .task {
                await SharedTripSync.shared.ensureMyDisplayName(for: room)
                await loadMemberCount()
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
            .photosPicker(isPresented: $showsPhotoPicker, selection: $photoSelection,
                          maxSelectionCount: 9, selectionBehavior: .ordered, matching: .images)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                sendPhotos(items, in: room)
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                for url in (try? result.get()) ?? [] { sendFile(url, in: room) }
            }
    }

    // MARK: 工具栏

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
                Toggle(isOn: Binding(get: { room.muted }, set: {
                    room.muted = $0
                    try? context.save()
                })) {
                    Label("免打扰", systemImage: "bell.slash")
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

    // MARK: 输入区

    /// 待回答的提问卡滚出屏幕时,输入栏上方的一颗 Liquid Glass 圆角矩形:「问题:… ›」,
    /// 点了滚回那张卡。答完(或者已经汇总)就消失。
    private func askPill(_ ask: ChatPendingAsk) -> some View {
        Button {
            scrollRequest = ask.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.tint)
                Text("问题:\(ask.question)")
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(minHeight: DesignMetrics.minimumHitTarget)
            .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
            .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous))
        }
        .pressableCard()
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityHint("滚动到这个问题")
    }

    @ViewBuilder
    private func statusBanner(_ room: ChatRoom) -> some View {
        if let thought = aiThought ?? coordinator.running[roomUUID] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(thought)
                    .lineLimit(1)
                if aiThought != nil {
                    Button("停止") { aiTask?.cancel() }
                        .font(.footnote.weight(.semibold))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        } else if let message = errorText ?? coordinator.errors[roomUUID] ?? (preparingShare
            ? String(localized: "正在建立共享…", bundle: .appLanguage())
            : preparing > 0 ? String(localized: "正在准备分享的内容…", bundle: .appLanguage()) : nil) {
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

    /// 输入栏左边的「+」:照片、文件,以及把 app 里的内容(旅行、资产…)分享进聊天。
    /// 和 AI 页输入栏的「+」同一个外观(玻璃圆,不用 `.glassButton()`,理由见
    /// `AgentView.attachButton`)。
    private var shareMenu: some View {
        Menu {
            Button {
                showsPhotoPicker = true
            } label: {
                Label("照片", systemImage: "photo")
            }
            Button {
                showsFileImporter = true
            } label: {
                Label("文件", systemImage: "doc")
            }
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

    // MARK: 发送

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ room: ChatRoom) {
        guard canSend else { return }
        SharedTripSync.shared.send(text, in: room)
        text = ""
        if room.aiEnabled { runAI(room) }
    }

    /// 分享几条内容进聊天:内容快照现在就取(用户看到的就是发出去的那一版),
    /// 已经共享过的旅行/资产台账再取一下共享链接,取完按选择顺序发出。
    private func shareCards(_ references: [AgentReference], in room: ChatRoom) {
        let cards = references.map { reference in
            ChatCard(reference: reference, body: AgentReferenceRenderer.body(for: reference, in: context))
        }
        preparing += 1
        Task {
            defer { preparing -= 1 }
            for var card in cards {
                card.shareURL = await SharedTripSync.shared.existingShareURL(for: card.reference)?.absoluteString
                SharedTripSync.shared.send(card, in: room)
            }
        }
    }

    /// 按选择顺序逐张读;相册原图可能是 HEIC、很大,转成 JPEG、长边压到 2048 再发
    /// (每张图都要传给每个成员)。
    private func sendPhotos(_ items: [PhotosPickerItem], in room: ChatRoom) {
        preparing += 1
        Task {
            defer { preparing -= 1 }
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let jpeg = ChatImage.normalized(data)
                if !SharedTripSync.shared.sendAttachment(
                    data: jpeg, fileName: "IMG-\(UUID().uuidString.prefix(8)).jpg", kind: .image, in: room) {
                    errorText = String(localized: "文件太大了,聊天里一次最多发 50 MB", bundle: .appLanguage())
                }
            }
        }
    }

    private func sendFile(_ url: URL, in room: ChatRoom) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= SharedTripMapping.maxAssetBytes else {
            errorText = String(localized: "文件太大了,聊天里一次最多发 50 MB", bundle: .appLanguage())
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorText = String(localized: "读不了这个文件", bundle: .appLanguage())
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if !SharedTripSync.shared.sendAttachment(data: isImage ? ChatImage.normalized(data) : data,
                                                 fileName: url.lastPathComponent,
                                                 kind: isImage ? .image : .file, in: room) {
            errorText = String(localized: "文件太大了,聊天里一次最多发 50 MB", bundle: .appLanguage())
        }
    }

    // MARK: AI

    /// 这台设备的 AI 看一遍聊天记录再回话;上一轮还在跑就先停掉(以最新那句为准)。
    /// 提问的汇总不走这里,见 `ChatAskCoordinator`。
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

    private func loadMemberCount() async {
        let members = await SharedTripSync.shared.members(kind: .chat, containerUUID: roomUUID)
        let accepted = members.filter(\.accepted).count
        memberCount = accepted > 0 ? accepted : nil
    }

    // MARK: 其他

    private func markRead(_ room: ChatRoom) {
        guard room.lastMessageAt > room.lastReadAt else { return }
        room.lastReadAt = room.lastMessageAt
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
                await loadMemberCount()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// 一张待我回答的提问卡(时间线报给外层,滚出屏幕时显示「问题:… ›」)。
struct ChatPendingAsk: Equatable {
    let id: UUID
    let question: String
}

enum ChatImage {
    /// 相册/文件里的图片转成 JPEG、长边不超过 2048。
    static func normalized(_ data: Data) -> Data {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return data }
        let longest = max(image.size.width, image.size.height)
        guard longest > 2048 else { return image.jpegData(compressionQuality: 0.8) ?? data }
        let scale = 2048 / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8) ?? data
        #elseif os(macOS)
        // Mac 上同样压:原图(尤其 HEIC/RAW)可能几十 MB,超过 50 MB 就发不出去。
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? data
        #else
        return data
        #endif
    }
}

// MARK: - 时间线

/// 消息列表。普通 VStack 而不是 LazyVStack,每条消息(连同它上面那行时间)是**一个**带 id
/// 的视图:同 AI 助手页,scrollTo 才不会落空。窗口外的更早消息不取(`window`)。
private struct ChatTimeline: View {
    let roomUUID: UUID
    let window: Int
    /// 刚点了「载入更早的消息」时的那一条:重建后停在它这儿。
    let anchor: UUID?
    let isOwner: Bool
    let memberCount: Int?
    @Binding var scrollRequest: UUID?
    @Binding var offscreenAsk: ChatPendingAsk?
    let bottomTick: Int
    let onLoadEarlier: (UUID?) -> Void
    let onInvite: () -> Void
    let onAnswer: ([[String]], ChatRoomMessage) -> Void
    let onSummarize: (ChatRoomMessage) -> Void
    let onRecall: (ChatRoomMessage) -> Void
    let onNewMessages: () -> Void

    @Query private var newestFirst: [ChatRoomMessage]
    @State private var askFrames: [UUID: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0

    init(roomUUID: UUID, window: Int, anchor: UUID?, isOwner: Bool, memberCount: Int?,
         scrollRequest: Binding<UUID?>, offscreenAsk: Binding<ChatPendingAsk?>, bottomTick: Int,
         onLoadEarlier: @escaping (UUID?) -> Void, onInvite: @escaping () -> Void,
         onAnswer: @escaping ([[String]], ChatRoomMessage) -> Void,
         onSummarize: @escaping (ChatRoomMessage) -> Void,
         onRecall: @escaping (ChatRoomMessage) -> Void,
         onNewMessages: @escaping () -> Void) {
        self.roomUUID = roomUUID
        self.window = window
        self.anchor = anchor
        self.isOwner = isOwner
        self.memberCount = memberCount
        _scrollRequest = scrollRequest
        _offscreenAsk = offscreenAsk
        self.bottomTick = bottomTick
        self.onLoadEarlier = onLoadEarlier
        self.onInvite = onInvite
        self.onAnswer = onAnswer
        self.onSummarize = onSummarize
        self.onRecall = onRecall
        self.onNewMessages = onNewMessages
        // 多取一条,用来判断顶上还要不要「载入更早的消息」。
        var descriptor = FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == roomUUID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = window + 1
        _newestFirst = Query(descriptor)
    }

    private var hasEarlier: Bool { newestFirst.count > window }

    /// 窗口内的消息,按时间正序、按 uuid 去重(含不显示的标记,状态要用)。
    private var windowMessages: [ChatRoomMessage] {
        var seen = Set<UUID>()
        return newestFirst.prefix(window).reversed().filter { seen.insert($0.uuid).inserted }
    }

    var body: some View {
        let all = windowMessages
        let state = ChatTimelineState(messages: all)
        let list = all.filter { $0.kind != .marker }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if list.isEmpty {
                        emptyHint
                    }
                    if hasEarlier {
                        Button("载入更早的消息") { onLoadEarlier(list.first?.uuid) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.uuid) { index, message in
                        VStack(spacing: 8) {
                            if showsTimestamp(list, at: index) {
                                Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                            }
                            ChatMessageBubble(
                                message: message, showsSender: showsSender(list, at: index),
                                state: state, memberCount: memberCount,
                                onAnswer: { onAnswer($0, message) },
                                onSummarize: { onSummarize(message) },
                                onRecall: { onRecall(message) })
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
            .coordinateSpace(name: ChatAskFrameKey.space)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
                }
            }
            .onPreferenceChange(ChatAskFrameKey.self) { frames in
                askFrames = frames
                updateOffscreenAsk(state)
            }
            .onChange(of: viewportHeight) { _, _ in updateOffscreenAsk(state) }
            .onChange(of: state.pendingAsk?.uuid) { _, _ in updateOffscreenAsk(state) }
            .defaultScrollAnchor(.bottom)
            .softTopScrollEdgeTransition()
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                // 载入更早的消息之后停在原来最上面那条(不然一重建就跳回底部,等于没载)。
                if let anchor {
                    proxy.scrollTo(anchor, anchor: .top)
                } else {
                    scrollToBottom(proxy, list)
                }
                updateOffscreenAsk(state)
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification)) { _ in scrollToBottom(proxy, list) }
            #endif
            .onChange(of: list.count) { _, _ in
                scrollToBottom(proxy, list)
                onNewMessages()
            }
            // 输入区高度变化是带动画的(提示行、「问题」按钮 0.2 秒滑入),等它落定再滚,
            // 不然按动画开始前的高度算,最后一条还是被压住一截。
            .onChange(of: bottomTick) { _, _ in scrollToBottom(proxy, list, after: 0.3) }
            .onChange(of: scrollRequest) { _, target in
                guard let target else { return }
                withAnimation(.lodoAware(.snappy(duration: 0.3))) { proxy.scrollTo(target, anchor: .center) }
                scrollRequest = nil
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text(isOwner ? LocalizedStringKey("邀请朋友加入,开始聊天") : "还没有消息")
                .font(.headline)
            if isOwner {
                Button("邀请成员", action: onInvite)
                    .glassProminentButton()
            }
        }
        .padding(.vertical, 60)
    }

    /// 待我回答的那张提问卡在不在可视范围里;不在就把它报给外层,输入栏上方挂一颗按钮。
    /// 底部留出输入区的高度(时间线铺在输入栏背后),顶上留出导航栏那截。
    private func updateOffscreenAsk(_ state: ChatTimelineState) {
        guard let ask = state.pendingAsk, let question = ask.ask?.questions.first?.question else {
            if offscreenAsk != nil { offscreenAsk = nil }
            return
        }
        let visible = askFrames[ask.uuid].map { frame in
            frame.maxY > 80 && frame.minY < viewportHeight - 140
        } ?? false
        let next = visible ? nil : ChatPendingAsk(id: ask.uuid, question: question)
        if next != offscreenAsk { offscreenAsk = next }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, _ list: [ChatRoomMessage],
                                after delay: TimeInterval = 0) {
        guard let last = list.last else { return }
        // 等这一帧的输入区高度定下来再滚。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.lodoAware(.snappy(duration: 0.25))) {
                proxy.scrollTo(last.uuid, anchor: .bottom)
            }
        }
    }

    /// 和上一条隔了 10 分钟以上(或是第一条)就插一行时间。
    private func showsTimestamp(_ list: [ChatRoomMessage], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return list[index].createdAt.timeIntervalSince(list[index - 1].createdAt) > 600
    }

    /// 别人连续发的几条只在第一条上面写名字。
    private func showsSender(_ list: [ChatRoomMessage], at index: Int) -> Bool {
        let message = list[index]
        guard !message.fromMe, message.kind != .system else { return false }
        guard index > 0, !showsTimestamp(list, at: index) else { return true }
        let previous = list[index - 1]
        return previous.fromMe || previous.senderName != message.senderName || previous.kind != message.kind
    }
}

/// 时间线上各条消息之间的关系:谁答了哪次提问、哪张提案卡被谁写入/撤销了。
/// 从窗口内的消息现算(提问的回答、写入提示都在它们指向的那条之后,同在窗口里)。
struct ChatTimelineState {
    let asks: [ChatRoomMessage]
    private let replies: [UUID: [ChatRoomMessage]]
    private let refs: [(ref: ChatProposalRef, by: String, fromMe: Bool, at: Date)]

    init(messages: [ChatRoomMessage]) {
        asks = messages.filter { $0.kind == .ask }
        var replies: [UUID: [ChatRoomMessage]] = [:]
        for message in messages where message.kind == .askAnswer {
            if let askID = message.reply?.askID { replies[askID, default: []].append(message) }
        }
        self.replies = replies
        refs = messages.compactMap { message in
            message.ref.map { ($0, message.senderName, message.fromMe, message.createdAt) }
        }
    }

    func respondents(_ askID: UUID) -> Set<String> {
        ChatAskTally.respondents((replies[askID] ?? []).map { ($0.senderID, $0.fromMe) })
    }

    func myAnswer(_ askID: UUID) -> [[String]]? {
        replies[askID]?.last { $0.fromMe }?.reply?.answers
    }

    func isClosed(_ askID: UUID) -> Bool {
        ChatProposalRef.latest(refs, messageID: askID, part: "ask")?.action == .applied
    }

    /// 最近一张还没汇总、我也还没回答的提问。
    var pendingAsk: ChatRoomMessage? {
        asks.last { !isClosed($0.uuid) && myAnswer($0.uuid) == nil }
    }

    func latestRef(_ messageID: UUID, part: String) -> (action: ChatProposalRef.Action, by: String, fromMe: Bool)? {
        ChatProposalRef.latest(refs, messageID: messageID, part: part)
    }
}

/// 提问卡在滚动视图里的位置(判断它是不是滚出屏幕了)。
struct ChatAskFrameKey: PreferenceKey {
    static let space = "chatTimeline"
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
