import XCTest
@testable import LodoCore

/// QwenASRClient 的纯函数部分(请求体构建/响应解析)离线单测,不发网络请求。
final class QwenASRClientTests: XCTestCase {
    func testRequestBodyEncodesBase64DataURL() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46])
        let body = QwenASRClient.requestBody(wavData: wav)

        XCTAssertEqual(body["model"] as? String, "qwen3-asr-flash")
        XCTAssertEqual(body["stream"] as? Bool, false)
        guard let messages = body["messages"] as? [[String: Any]], messages.count == 1,
              let content = messages[0]["content"] as? [[String: Any]], content.count == 1,
              let inputAudio = content[0]["input_audio"] as? [String: String],
              let data = inputAudio["data"] else {
            XCTFail("unexpected request body shape")
            return
        }
        XCTAssertEqual(data, "data:audio/wav;base64,\(wav.base64EncodedString())")
    }

    func testParseTranscriptExtractsMessageContent() throws {
        let root: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": " 明天下午三点开会 "]]],
        ]
        let text = try QwenASRClient.parseTranscript(root)
        XCTAssertEqual(text, "明天下午三点开会")
    }

    func testParseTranscriptThrowsOnMissingChoices() {
        XCTAssertThrowsError(try QwenASRClient.parseTranscript([:])) { error in
            XCTAssertTrue(error is QwenASRError)
        }
    }

    func testParseTranscriptThrowsOnMissingContent() {
        let root: [String: Any] = ["choices": [["message": ["role": "assistant"]]]]
        XCTAssertThrowsError(try QwenASRClient.parseTranscript(root)) { error in
            XCTAssertTrue(error is QwenASRError)
        }
    }
}
