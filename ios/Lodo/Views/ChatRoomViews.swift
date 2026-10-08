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
                HStack(spacing: 4) {
                    Text(room.title.isEmpty ? String(localized: "新聊天室", bundle: .appLanguage()) : room.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if room.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("免打扰")
                    }
                }
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

// MARK: - 销毁 / 退出确认

extension View {
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

// MARK: - AI 页右上角的入口

/// AI 助手页右上角的「聊天室」按钮:任何房间有别人发的未读消息时挂一个小红点。
struct ChatRoomsToolbarButton: View {
    let action: () -> Void

    @Environment(\.modelContext) private var context
    /// 房间的 lastMessageAt / lastReadAt 一变(收到新消息、读过),这里跟着重算。
    @Query private var rooms: [ChatRoom]

    private var hasUnread: Bool {
        rooms.contains { room in
            guard room.lastMessageAt > room.lastReadAt else { return false }
            let id = room.uuid
            let read = room.lastReadAt
            return ((try? context.fetchCount(FetchDescriptor<ChatRoomMessage>(
                predicate: #Predicate { $0.roomUUID == id && !$0.fromMe && $0.createdAt > read }))) ?? 0) > 0
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.bubble.right")
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(LodoColor.critical)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .accessibilityLabel(hasUnread ? "聊天室,有新消息" : "聊天室")
    }
}
