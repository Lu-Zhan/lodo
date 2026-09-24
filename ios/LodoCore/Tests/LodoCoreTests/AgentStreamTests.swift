import XCTest
@testable import LodoCore

/// SSE 行解析 + answer 增量抽取 + 节流的离线单测(不发任何请求)。
final class AgentStreamTests: XCTestCase {

    // MARK: - SSE 行解析

    func testParsesContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        XCTAssertEqual(AgentStream.parseLine(line), .delta(content: "你好", reasoning: nil))
    }

    func testParsesReasoningDelta() {
        let line = #"data: {"choices":[{"delta":{"reasoning_content":"先想想"}}]}"#
        XCTAssertEqual(AgentStream.parseLine(line), .delta(content: nil, reasoning: "先想想"))
    }

    /// 另一些 OpenAI 兼容服务商用 `reasoning` 而不是 `reasoning_content`。
    func testParsesAlternateReasoningKey() {
        let line = #"data: {"choices":[{"delta":{"reasoning":"嗯"}}]}"#
        XCTAssertEqual(AgentStream.parseLine(line), .delta(content: nil, reasoning: "嗯"))
    }

    func testParsesDone() {
        XCTAssertEqual(AgentStream.parseLine("data: [DONE]"), .done)
    }

    func testIgnoresBlankHeartbeatAndUnknownLines() {
        XCTAssertNil(AgentStream.parseLine(""))
        XCTAssertNil(AgentStream.parseLine("   "))
        XCTAssertNil(AgentStream.parseLine(": keep-alive"))
        XCTAssertNil(AgentStream.parseLine("event: message"))
        XCTAssertNil(AgentStream.parseLine(#"data: {"id":"x"}"#))
        XCTAssertNil(AgentStream.parseLine(#"data: {"choices":[{"delta":{}}]}"#))
    }

    // MARK: - answer 增量抽取

    /// 把同一段 JSON 按每一个可能的位置切成两片喂进去,结果都要一致 ——
    /// 真实的 SSE 分片位置是随机的,包括切在转义序列中间。
    func testEmitsSameTextRegardlessOfChunkBoundaries() {
        let json = #"{"actions":[{"action":"answer","text":"你好\n世界"}]}"#
        for cut in 1..<json.count {
            var scanner = AnswerStreamScanner()
            let head = String(json.prefix(cut))
            let tail = String(json.dropFirst(cut))
            _ = scanner.consume(head)
            _ = scanner.consume(tail)
            XCTAssertEqual(scanner.currentText, "你好\n世界", "切在第 \(cut) 个字符时不一致")
        }
    }

    /// 逐字符喂:吐出的文本必须单调增长,且任何中间态都不能出现反斜杠残留。
    func testTextGrowsMonotonicallyAndNeverShowsHalfEscape() {
        let json = #"{"actions":[{"action":"answer","text":"第一行\n第二行中"}]}"#
        var scanner = AnswerStreamScanner()
        var previous = ""
        for character in json {
            _ = scanner.consume(String(character))
            let now = scanner.currentText
            XCTAssertTrue(now.hasPrefix(previous), "文本回退了:\(previous) → \(now)")
            XCTAssertFalse(now.contains("\\"), "露出了半个转义序列:\(now)")
            previous = now
        }
        XCTAssertEqual(scanner.currentText, "第一行\n第二行中")
    }

    /// 代理对(emoji)必须等配对的低位代理项到齐才吐,否则是个乱码方块。
    func testWaitsForSurrogatePair() {
        var scanner = AnswerStreamScanner()
        _ = scanner.consume(#"{"actions":[{"action":"answer","text":"好\uD83D"#)
        XCTAssertEqual(scanner.currentText, "好")
        _ = scanner.consume(#"\uDE00"}]}"#)
        XCTAssertEqual(scanner.currentText, "好😀")
    }

    /// 写操作一个字都不吐。
    func testStaysSilentForCreateAction() {
        var scanner = AnswerStreamScanner()
        let json = #"{"actions":[{"action":"create","title":"开会","text":"不该出现"}]}"#
        XCTAssertNil(scanner.consume(json))
        XCTAssertEqual(scanner.currentText, "")
        XCTAssertTrue(scanner.isRejected)
    }

    /// memorize/auto_memorize 的 payload 里同样有 text,只扫键会把记忆正文
    /// 先流进气泡再被收藏卡片顶掉——必须按 action 的值门控。
    func testStaysSilentForMemorizeAction() {
        for action in ["memorize", "auto_memorize", "suggest_memorize"] {
            var scanner = AnswerStreamScanner()
            let json = #"{"actions":[{"action":"\#(action)","text":"班主任喜欢收贺卡"}]}"#
            XCTAssertNil(scanner.consume(json), action)
            XCTAssertEqual(scanner.currentText, "", action)
        }
    }

    /// text 排在 action 前面时先缓冲,确认是 answer 才补吐。
    func testBuffersWhenTextComesBeforeAction() {
        var scanner = AnswerStreamScanner()
        XCTAssertNil(scanner.consume(#"{"actions":[{"text":"稍等","#))
        XCTAssertEqual(scanner.currentText, "")
        _ = scanner.consume(#""action":"answer"}]}"#)
        XCTAssertEqual(scanner.currentText, "稍等")
    }

    /// ReAct 的工具调用轮次根本没有 actions,天然安静——
    /// 所以不需要预判"哪一轮才是最后一轮"。
    func testStaysSilentForToolCall() {
        var scanner = AnswerStreamScanner()
        let json = #"{"thought":"先查一下","tool":"web_search","query":"天气"}"#
        XCTAssertNil(scanner.consume(json))
        XCTAssertEqual(scanner.currentText, "")
    }

    /// 断流(JSON 只收到一半)不崩,已经吐出去的内容也不回退。
    func testTruncatedJSONKeepsWhatWasAlreadyShown() {
        var scanner = AnswerStreamScanner()
        _ = scanner.consume(#"{"actions":[{"action":"answer","text":"说到一半"#)
        XCTAssertEqual(scanner.currentText, "说到一半")
    }

    /// answer 之外还带了别的字段时照常抽。
    func testHandlesExtraFieldsBeforeText() {
        var scanner = AnswerStreamScanner()
        let json = #"{"reply":"x","actions":[{"action":"answer","related":[1,2],"text":"好的"}]}"#
        _ = scanner.consume(json)
        XCTAssertEqual(scanner.currentText, "好的")
    }

    // MARK: - 节流

    func testThrottleLetsFirstDeltaThrough() {
        var throttle = StreamThrottle()
        XCTAssertTrue(throttle.shouldFlush("你", now: Date(timeIntervalSince1970: 0)))
    }

    func testThrottleHoldsBackRapidDeltas() {
        let start = Date(timeIntervalSince1970: 0)
        var throttle = StreamThrottle()
        XCTAssertTrue(throttle.shouldFlush("你", now: start))
        XCTAssertFalse(throttle.shouldFlush("好", now: start.addingTimeInterval(0.01)))
        XCTAssertFalse(throttle.shouldFlush("吗", now: start.addingTimeInterval(0.02)))
        XCTAssertTrue(throttle.shouldFlush("?", now: start.addingTimeInterval(0.2)))
    }

    /// 换行视觉上正好是一段结束,不等节流间隔直接放行。
    func testThrottleFlushesOnNewline() {
        let start = Date(timeIntervalSince1970: 0)
        var throttle = StreamThrottle()
        XCTAssertTrue(throttle.shouldFlush("你", now: start))
        XCTAssertTrue(throttle.shouldFlush(#"\n"#, now: start.addingTimeInterval(0.01)))
    }
}
