import Foundation
import SwiftData
import OSLog
import LodoCore

/// 共享聊天室里的 AI(输入栏左边那颗「AI」开着时,每发一条消息由**这台设备**调一次)。
///
/// 和「我的 AI 助手」(`AgentHostView.route`)共用同一个 `command` 协议与 skill,区别:
/// - 输入是房间最近的聊天记录(`ChatTranscript`),不是一句话 + 私人对话历史;
/// - **不给私人数据**:任务、记忆、资产、健康、偏好、倒数日清单都不进 prompt——回复全房间
///   都看得到。能读的只有已经共享出去的旅行(`read_trip` 只在共享旅行里挑);
/// - **不执行任何写操作**:动作收成一份 `ChatProposal` 跟着回复发进房间,成员在卡片上
///   各自确认后才写(见 `ChatProposalView`)。
@MainActor
enum ChatRoomAI {
    static let log = Logger(subsystem: "com.lodo.app", category: "ChatRoomAI")

    enum Failure: LocalizedError {
        case notConfigured
        var errorDescription: String? {
            String(localized: "还没有配置 AI,去「设置 → AI 设置」里选一个服务商", bundle: .appLanguage())
        }
    }

    static func respond(in room: ChatRoom, context: ModelContext,
                        onThought: (String) -> Void) async throws {
        guard DeepSeekClient.isConfigured else { throw Failure.notConfigured }
        let roomUUID = room.uuid
        var seen = Set<UUID>()
        let messages = ((try? context.fetch(FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == roomUUID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { seen.insert($0.uuid).inserted }
        let transcript = ChatTranscript.build(messages.map { message in
            ChatTranscript.Entry(sender: message.senderName, isMe: message.fromMe, kind: message.kind,
                                 content: message.content, cardBody: message.card?.body,
                                 createdAt: message.createdAt)
        })
        let request = "聊天记录:\n\(transcript)\n\n请根据以上聊天记录,回应「我」最新说的话。"
        let sharedTrips = TravelStore.trips(in: context).filter(\.isShared)
        let groupBlock = GroupChatPrompt.block(roomTitle: room.title,
                                               requester: SharedTripSync.myDisplayName)

        var history: [(role: String, content: String)] = []
        var currentText = request
        for _ in 0..<3 {
            let result: AICommandResult
            do {
                result = try await DeepSeekClient.command(
                currentText, tasks: [], memoryEnabled: false,
                webSearchEnabled: WebSearchClient.isConfigured,
                travelEnabled: !sharedTrips.isEmpty, tripPlanEnabled: true,
                countdownEnabled: true, countdowns: [],
                groupChat: groupBlock, history: history)
            } catch {
                // 解析失败时错误只说"返回格式异常",原文写进日志
                // (Console.app 里按 subsystem com.lodo.app、category ChatRoomAI 过滤)。
                log.error("""
                    room AI failed: \(error.localizedDescription, privacy: .public) \
                    raw: \(DeepSeekClient.lastMalformedText ?? "-", privacy: .public)
                    """)
                throw error
            }
            switch result {
            case .ask(let questions):
                // 群聊里没有可交互的询问卡:把问题列出来,大家在聊天里接着说。
                let lines = questions.enumerated().map { "\($0.offset + 1). \($0.element.question)" }
                post(String(localized: "想先确认几件事:", bundle: .appLanguage()) + "\n"
                     + lines.joined(separator: "\n"), proposal: nil, in: room)
                return
            case .toolCall(let thought, let tool):
                onThought(thought)
                let (call, observation) = await observe(tool, sharedTrips: sharedTrips, context: context)
                history.append((role: "assistant", content: "思考:\(thought);\(call)"))
                history.append((role: "user", content: observation))
                currentText = "(请基于以上结果继续处理:\(request))"
            case .actions(let actions):
                let (text, proposal) = collect(actions)
                post(text, proposal: proposal, in: room)
                return
            }
        }
        throw DeepSeekError.parse("多轮推理超过上限,换个说法试试")
    }

    private static func post(_ text: String, proposal: ChatProposal?, in room: ChatRoom) {
        SharedTripSync.shared.sendAI(text, proposal: proposal, in: room)
    }

    /// 只读工具。群聊里只开联网和读**共享**旅行,别的一律如实说不可用。
    private static func observe(_ tool: AITool, sharedTrips: [TravelTrip],
                                context: ModelContext) async -> (call: String, observation: String) {
        switch tool {
        case .webSearch(let query):
            let observation: String
            do {
                let results = try await WebSearchClient.search(query)
                observation = results.isEmpty ? "没有搜到相关结果" :
                    results.map { "「\($0.title)」\($0.snippet)\n来源:\($0.url)" }.joined(separator: "\n\n")
            } catch {
                observation = "联网搜索失败:\(error.localizedDescription)"
            }
            return ("联网搜索:\(query)", "搜索结果:\n\(observation)")
        case .webFetch(let urlString):
            guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
                return ("抓取链接:\(urlString)", "链接内容:\n无效链接")
            }
            let extraction = await ContentExtractor.extract(url: url)
            return ("抓取链接:\(urlString)",
                    "链接内容:\n" + (extraction.text.isEmpty ? "抓取失败或页面无正文内容" : extraction.text))
        case .readTrip(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trip = sharedTrips.first { !trimmed.isEmpty && $0.title.localizedStandardContains(trimmed) }
                ?? sharedTrips.first { $0.isOngoing() } ?? sharedTrips.first
            let observation = trip.map { TravelStore.promptSummary(for: $0, includeIDs: true, in: context) }
                ?? "这个聊天室里没有已经共享的旅行"
            return ("读行程:\(trimmed.isEmpty ? "当前旅行" : trimmed)", "行程:\n\(observation)")
        default:
            return ("调用工具", "这个工具在群聊里不可用(不读成员的私人数据)")
        }
    }

    /// 动作 → 一句回复 + 待确认的提案。群聊里不认的动作丢掉。
    static func collect(_ actions: [AIAction]) -> (text: String, proposal: ChatProposal?) {
        var answers: [String] = []
        var proposal = ChatProposal()
        for action in actions {
            switch action {
            case .answer(let text): answers.append(text)
            case .planTrip(let plan): proposal.tripPlan = plan
            case .editTrip(let edit): proposal.tripEdit = edit
            case .create(let parsed): proposal.tasks.append(parsed)
            case .countdown(.create(let draft)): proposal.countdowns.append(draft)
            default: break
            }
        }
        var text = answers.joined(separator: "\n")
        if text.isEmpty {
            text = proposal.tripPlan.map { $0.summary.isEmpty ? "整理了一份行程「\($0.tripTitle)」。" : $0.summary }
                ?? proposal.tripEdit.map { $0.summary.isEmpty ? "整理了对「\($0.tripTitle)」的调整。" : $0.summary }
                ?? (proposal.isEmpty ? "这个在群聊里做不了,可以到「我的 AI 助手」里说。" : "整理好了,确认后写入。")
        }
        return (text, proposal.isEmpty ? nil : proposal)
    }
}
