import SwiftUI
import SwiftData
import LodoCore

/// 「共享与权限」(侧栏底部「设置」旁边那颗):这台设备上所有经 CloudKit 共享的东西汇在一页——
/// 聊天室、共享旅行、资产台账。每一项能看成员和接受状态,能邀请/管理成员(系统共享界面),
/// 能停止共享 / 退出 / 销毁。原来散在旅行详情菜单、资产确认页、聊天室菜单里的入口都还在,
/// 这一页是汇总。
///
/// 权限只有「可编辑」一档(用户确认过):邀请都按可编辑发,这里只如实显示。
struct SharingCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ChatRoom> { $0.shareRoleRaw != "" }, sort: \ChatRoom.lastMessageAt,
           order: .reverse) private var rooms: [ChatRoom]
    @Query(filter: #Predicate<TravelTrip> { $0.shareRoleRaw != "" }, sort: \TravelTrip.startDate,
           order: .reverse) private var trips: [TravelTrip]
    private let sync = SharedTripSync.shared

    private var uniqueRooms: [ChatRoom] {
        var seen = Set<UUID>()
        return rooms.filter { seen.insert($0.uuid).inserted }
    }

    private var uniqueTrips: [TravelTrip] {
        var seen = Set<UUID>()
        return trips.filter { seen.insert($0.uuid).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                if !sync.isAvailable {
                    Section {
                        Label("请先在系统设置里登录 iCloud", systemImage: "icloud.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                if !uniqueRooms.isEmpty {
                    Section("聊天室") {
                        ForEach(uniqueRooms) { room in
                            NavigationLink(value: ShareTarget.chat(room.uuid)) {
                                ShareRow(title: room.title, symbol: "bubble.left.and.bubble.right",
                                         isOwner: room.isOwner)
                            }
                        }
                    }
                }
                if !uniqueTrips.isEmpty {
                    Section("旅行") {
                        ForEach(uniqueTrips) { trip in
                            NavigationLink(value: ShareTarget.trip(trip.uuid)) {
                                ShareRow(title: trip.displayEmoji + " " + trip.title, symbol: "airplane",
                                         isOwner: trip.shareRole == .owner)
                            }
                        }
                    }
                }
                if let assets = sync.assetShare {
                    Section("资产") {
                        NavigationLink(value: ShareTarget.assets(assets.ledgerUUID)) {
                            ShareRow(title: String(localized: "资产台账", bundle: .appLanguage()),
                                     symbol: "creditcard", isOwner: assets.role == .owner)
                        }
                    }
                }
            }
            .overlay {
                if uniqueRooms.isEmpty && uniqueTrips.isEmpty && sync.assetShare == nil {
                    ContentUnavailableView(
                        "还没有共享任何内容", systemImage: "person.2",
                        description: Text("共享的旅行、资产台账和聊天室都会列在这里。"))
                    .emptyStateFill()
                }
            }
            .navigationDestination(for: ShareTarget.self) { target in
                ShareDetailView(target: target)
            }
            .pageTitle("共享与权限")
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
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

/// 列表里的一项共享。
enum ShareTarget: Hashable {
    case chat(UUID)
    case trip(UUID)
    case assets(UUID)

    var kind: SharedZoneKind {
        switch self {
        case .chat: return .chat
        case .trip: return .trip
        case .assets: return .assets
        }
    }

    var containerUUID: UUID {
        switch self {
        case .chat(let id), .trip(let id), .assets(let id): return id
        }
    }
}

private struct ShareRow: View {
    let title: String
    let symbol: String
    let isOwner: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(isOwner ? LocalizedStringKey("我创建的") : "我加入的")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 详情

/// 一份共享的成员与操作。
private struct ShareDetailView: View {
    let target: ShareTarget

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var members: [SharedTripSync.ShareMember]?
    @State private var working = false
    @State private var errorText: String?
    @State private var confirmingStop = false

    private var sync: SharedTripSync { .shared }

    var body: some View {
        List {
            Section {
                if let members {
                    if members.isEmpty {
                        Text("取不到成员信息(离线或 iCloud 暂时不可用)")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(members) { member in
                        memberRow(member)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取成员…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("成员")
            } footer: {
                Text("成员都可以查看和编辑。要邀请新成员或移除某位成员,点下面的「邀请或管理成员」。")
            }

            Section {
                Button {
                    manage()
                } label: {
                    Label(isOwner ? "邀请或管理成员" : "查看成员", systemImage: "person.badge.plus")
                }
                .disabled(working)
                Button(role: .destructive) {
                    confirmingStop = true
                } label: {
                    Label(stopTitle, systemImage: isOwner ? "xmark.circle" : "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(LodoColor.critical)
                } else {
                    Text(stopFooter)
                }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadMembers() }
        .refreshable { await loadMembers() }
        .confirmationDialog(stopTitle, isPresented: $confirmingStop, titleVisibility: .visible) {
            Button(stopTitle, role: .destructive) { stop() }
        } message: {
            Text(stopFooter)
        }
    }

    private func memberRow(_ member: SharedTripSync.ShareMember) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name)
                    if member.isMe {
                        Text("我").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(member.isOwner ? LocalizedStringKey("创建者")
                     : member.accepted ? "已加入" : "已邀请,还没接受")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(member.canEdit ? LocalizedStringKey("可编辑") : "只读")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 对象

    private var room: ChatRoom? {
        guard case .chat(let id) = target else { return nil }
        return try? context.fetch(FetchDescriptor<ChatRoom>(predicate: #Predicate { $0.uuid == id })).first
    }

    private var trip: TravelTrip? {
        guard case .trip(let id) = target else { return nil }
        return try? context.fetch(FetchDescriptor<TravelTrip>(predicate: #Predicate { $0.uuid == id })).first
    }

    private var isOwner: Bool {
        switch target {
        case .chat: return room?.isOwner ?? true
        case .trip: return trip?.shareRole != .participant
        case .assets: return sync.assetShare?.role != .participant
        }
    }

    private var title: String {
        switch target {
        case .chat: return room?.title ?? ""
        case .trip: return trip?.title ?? ""
        case .assets: return String(localized: "资产台账", bundle: .appLanguage())
        }
    }

    private var stopTitle: String {
        switch (target, isOwner) {
        case (.chat, true): return String(localized: "销毁聊天室", bundle: .appLanguage())
        case (.chat, false): return String(localized: "退出聊天室", bundle: .appLanguage())
        case (_, true): return String(localized: "停止共享", bundle: .appLanguage())
        case (_, false): return String(localized: "退出共享", bundle: .appLanguage())
        }
    }

    private var stopFooter: String {
        switch (target, isOwner) {
        case (.chat, true):
            return String(localized: "所有成员的这个聊天室和全部消息都会被删除,不可恢复。", bundle: .appLanguage())
        case (.chat, false):
            return String(localized: "这台设备上的聊天记录会被删除,之后要有人重新邀请才能回来。", bundle: .appLanguage())
        case (_, true):
            return String(localized: "其他成员不能再看到和编辑,他们那边会留一份不再同步的副本;你这边的内容不变。", bundle: .appLanguage())
        case (_, false):
            return String(localized: "退出后这台设备上保留一份不再同步的副本。", bundle: .appLanguage())
        }
    }

    // MARK: 操作

    private func loadMembers() async {
        members = await sync.members(kind: target.kind, containerUUID: target.containerUUID)
    }

    private func manage() {
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                switch target {
                case .chat:
                    guard let room else { return }
                    let share = try await sync.prepareChatShare(for: room)
                    CloudSharingPresenter.present(share: share, room: room)
                case .trip:
                    guard let trip else { return }
                    let share = try await sync.prepareShare(for: trip)
                    CloudSharingPresenter.present(share: share, trip: trip)
                case .assets:
                    let share = try await sync.prepareAssetShare()
                    CloudSharingPresenter.presentAssets(share: share)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func stop() {
        switch target {
        case .chat:
            if let room { sync.destroyOrLeave(room) }
        case .trip:
            if let trip { sync.didStopSharing(trip) }
        case .assets:
            sync.didStopSharingAssets()
        }
        dismiss()
    }
}
