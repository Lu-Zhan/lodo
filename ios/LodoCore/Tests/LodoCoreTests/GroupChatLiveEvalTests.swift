import XCTest
@testable import LodoCore

/// 共享聊天室里的 AI:**真发请求**看群聊模式下模型给出的结构(同 `AgentLiveEvalTests`,
/// 默认跳过)。手动跑:
/// `LODO_LIVE_AI=1 LODO_LIVE_AI_LOG=/tmp/group-eval.log swift test --filter GroupChatLiveEvalTests`
final class GroupChatLiveEvalTests: XCTestCase {
    private func transcript(_ lines: [(String, Bool, String)]) -> String {
        let start = Date()
        return ChatTranscript.build(lines.enumerated().map { index, line in
            ChatTranscript.Entry(sender: line.0, isMe: line.1, kind: .text, content: line.2,
                                 createdAt: start.addingTimeInterval(Double(index) * 60))
        })
    }

    private func ask(_ chat: String) async throws -> AICommandResult {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LODO_LIVE_AI"] == "1",
                          "设置 LODO_LIVE_AI=1 才真发请求")
        let request = "聊天记录:\n\(chat)\n\n请根据以上聊天记录,回应「我」最新说的话。"
        do {
            let result = try await DeepSeekClient.command(
                request, tasks: [], memoryEnabled: false, tripPlanEnabled: true,
                countdownEnabled: true, groupChat: GroupChatPrompt.block(roomTitle: "京都五人行"))
            log(chat, "\(result)")
            return result
        } catch {
            log(chat, "ERROR \(error)\nRAW:\n\(DeepSeekClient.lastMalformedText ?? "-")")
            throw error
        }
    }

    private func log(_ chat: String, _ result: String) {
        guard let path = ProcessInfo.processInfo.environment["LODO_LIVE_AI_LOG"] else { return }
        let entry = "=== \(chat.suffix(80))\n\(result)\n\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 大家说定了行程、「我」认领订酒店:应该给出规划 + 一条任务(不执行,只是卡片)。
    func testSettledPlanBecomesPlanAndTask() async throws {
        let result = try await ask(transcript([
            ("小林", false, "下个月去京都吧,我 11 月 13 号才能出发"),
            ("", true, "可以,那 13 号到 17 号"),
            ("阿杰", false, "想去伏见稻荷和岚山,奈良也想去"),
            ("", true, "那就定了:第一天伏见稻荷和祇园,第二天岚山,第三天奈良,第四天清水寺,最后一天回来。AI 帮我们整理成行程吧,订酒店我来负责"),
        ]))
        guard case .actions(let actions) = result else { return XCTFail("expected actions, got \(result)") }
        XCTAssertTrue(actions.contains { if case .planTrip = $0 { return true } else { return false } },
                      "应该有 plan_trip:\(actions)")
        XCTAssertTrue(actions.contains { if case .create = $0 { return true } else { return false } },
                      "应该给「我」建订酒店的任务:\(actions)")
    }

    /// 还在争的事:回话列出分歧,不该替大家定规划。
    func testUndecidedDiscussionGetsAnswerOnly() async throws {
        let result = try await ask(transcript([
            ("小林", false, "住京都站附近吧,交通方便"),
            ("阿杰", false, "我觉得四条河原町好,吃饭多"),
            ("", true, "AI 你觉得住哪儿好?"),
        ]))
        guard case .actions(let actions) = result else { return XCTFail("expected actions, got \(result)") }
        XCTAssertTrue(actions.contains { if case .answer = $0 { return true } else { return false } })
        XCTAssertFalse(actions.contains { if case .planTrip = $0 { return true } else { return false } })
    }
}
