import Foundation
import SwiftData
import Observation
import LodoCore

/// 群里 AI 提问的自动汇总。原来挂在聊天页上(页面开着、消息数变了才检查),发起人不在
/// 那一页时提问会一直卡在"待汇总";现在由同步层在收到回答时调 `check`,进聊天页、
/// 自己答完时也调一次。
///
/// 几条规则:
/// - **只有发出这次提问的那台设备自动汇总**(`postedHere`,本机记录):同一个账号的
///   iPhone 和 iPad 都开着时不会各汇总一遍。别的设备上的发起人仍可以手动「现在汇总」。
/// - "大家都答完"的人数**每次现取**(已接受邀请的成员),不用进房间时缓存的那个——
///   中途有人加入时旧人数会让汇总提前。取不到人数时不自动汇总,只能手动。
/// - 同一次提问同时只跑一次;汇总发出去的回复带 `ask` ref,所有人的卡片变「已汇总」。
@MainActor
@Observable
final class ChatAskCoordinator {
    static let shared = ChatAskCoordinator()

    /// 正在汇总的房间 → 那一行提示文字(聊天页底部显示)。
    private(set) var running: [UUID: String] = [:]
    /// 最近一次汇总失败的说明(按房间)。
    var errors: [UUID: String] = [:]

    private init() {}

    private var context: ModelContext { AppDatabase.container.mainContext }

    // MARK: 本机发出的提问

    private static let postedKey = "chatAsksPostedHere"

    static func markPostedHere(_ askID: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: postedKey) ?? []
        ids.append(askID.uuidString)
        UserDefaults.standard.set(Array(ids.suffix(200)), forKey: postedKey)
    }

    static func postedHere(_ askID: UUID) -> Bool {
        UserDefaults.standard.stringArray(forKey: postedKey)?.contains(askID.uuidString) ?? false
    }

    // MARK: 检查 / 汇总

    /// 看看这个房间里本机发起的提问是不是大家都答完了,答完了就汇总。
    func check(roomUUID: UUID) {
        guard running[roomUUID] == nil, let room = fetchRoom(roomUUID) else { return }
        let state = ChatTimelineState(messages: messages(in: roomUUID))
        let candidates = state.asks.filter { $0.fromMe && Self.postedHere($0.uuid) && !state.isClosed($0.uuid) }
        guard !candidates.isEmpty else { return }
        Task {
            let members = await SharedTripSync.shared.members(kind: .chat, containerUUID: roomUUID)
            let accepted = members.filter(\.accepted).count
            for ask in candidates where ChatAskTally.isComplete(
                answered: state.respondents(ask.uuid).count, memberCount: accepted > 0 ? accepted : nil) {
                summarize(askID: ask.uuid, in: room)
                break
            }
        }
    }

    /// 汇总一次提问(自动或者发起人手动点「现在汇总」)。
    func summarize(askID: UUID, in room: ChatRoom) {
        let roomUUID = room.uuid
        guard running[roomUUID] == nil else { return }
        // 跑之前再确认一遍没被汇总过(可能刚从别的设备同步过来一条汇总)。
        let state = ChatTimelineState(messages: messages(in: roomUUID))
        guard !state.isClosed(askID) else { return }
        errors[roomUUID] = nil
        running[roomUUID] = String(localized: "我的 AI 正在汇总大家的选择…", bundle: .appLanguage())
        Task {
            defer { running[roomUUID] = nil }
            do {
                try await ChatRoomAI.respond(in: room, context: context, closingAsk: askID) { [weak self] thought in
                    self?.running[roomUUID] = thought
                }
            } catch is CancellationError {
            } catch {
                errors[roomUUID] = error.localizedDescription
            }
        }
    }

    private func fetchRoom(_ uuid: UUID) -> ChatRoom? {
        try? context.fetch(FetchDescriptor<ChatRoom>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func messages(in roomUUID: UUID) -> [ChatRoomMessage] {
        var seen = Set<UUID>()
        return ((try? context.fetch(FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == roomUUID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { seen.insert($0.uuid).inserted }
    }
}
