import Foundation

public enum QwenASRError: LocalizedError {
    case noKey
    case api(String)
    case parse(String)

    /// 文案与 DeepSeekError 同构,只是换成 Qwen 语音识别专用的 LK 词条
    /// (couldn_t_parse 是通用前缀,两边共用)。
    public var errorDescription: String? {
        let language = AppSettings.language
        switch self {
        case .noKey:
            return LocalizedStrings.text(.ios_core_qwen_asr_api_key_not_configured_set, language: language)
        case .api(let m):
            return LocalizedStrings.text(.ios_core_qwen_asr_request_failed, language: language)
                + LocalizedStrings.translate(m, language: language)
        case .parse(let m):
            return LocalizedStrings.text(.ios_core_couldn_t_parse, language: language)
                + LocalizedStrings.translate(m, language: language)
        }
    }
}

/// 阿里云百炼 MaaS 部署的 Qwen 语音识别(qwen3-asr-flash),OpenAI 兼容
/// 的 chat/completions 接口,一次请求整段音频拿整段转写结果(非流式)。
/// 放进 LodoCore 是为了和 DeepSeekClient 同层,将来 Watch App 需要的话可直接复用。
public enum QwenASRClient {
    /// 同时用作 BuiltInAPIKey/KeychainHelper 的服务商查找键,三处必须完全一致。
    public static let providerName = "Qwen 语音识别"
    private static let endpoint = URL(string:
        "https://llm-kff4se94wpiqfdoy.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!
    /// 注意:不是 qwen-audio-3.0-asr-flash——那个模型官方标注的调用方式是
    /// DashScope 原生协议(HTTP、DashScope SDK),请求体是完全不同的 input/
    /// parameters 结构;OpenAI 兼容的 chat/completions 协议官方只认
    /// qwen3-asr-flash,拿错模型名去打这个 endpoint 会直接 400。
    private static let model = "qwen3-asr-flash"

    /// 当前是否已配置可用(内置 key 或用户自存 key)。
    public static var isConfigured: Bool {
        KeychainHelper.effectiveSTTKey != nil
    }

    static func requestBody(wavData: Data) -> [String: Any] {
        let dataURL = "data:audio/wav;base64,\(wavData.base64EncodedString())"
        return [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "input_audio",
                    "input_audio": ["data": dataURL],
                ]],
            ]],
            "stream": false,
            "asr_options": ["enable_itn": false],
        ]
    }

    static func parseTranscript(_ root: [String: Any]) throws -> String {
        guard let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw QwenASRError.parse("返回格式异常")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// wavData:16kHz 单声道 PCM WAV,编码后需在 10MB 以内(官方限制)。
    public static func transcribe(wavData: Data) async throws -> String {
        guard let apiKey = KeychainHelper.effectiveSTTKey, !apiKey.isEmpty else {
            throw QwenASRError.noKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(wavData: wavData))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QwenASRError.api(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QwenASRError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenASRError.parse("返回格式异常")
        }
        return try parseTranscript(root)
    }
}
