#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// 苹果智能(Foundation Models)端侧推理:与云服务商同形的 JSON 传输层。
/// prompt 复用 DeepSeekClient 的全套指令(要求只返回 JSON),
/// 免 key、离线、数据不出设备;仅在支持 Apple Intelligence 的设备上可用。
@available(iOS 26.0, macOS 26.0, *)
enum FoundationModelsClient {
    /// 设备当前是否可用苹果智能。
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// 面向设置页的可用性说明。
    static var availabilityHint: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "苹果智能可用:免 key、离线,数据不出设备。"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "此设备不支持苹果智能。"
            case .appleIntelligenceNotEnabled:
                return "请先在系统设置中开启 Apple Intelligence。"
            case .modelNotReady:
                return "苹果智能模型准备中,请稍后再试。"
            @unknown default:
                return "苹果智能暂不可用。"
            }
        }
    }

    /// 端侧推理并解析出 JSON payload,形态与云端 payload 一致(含 error 检查)。
    static func payload(system: String, user: String) async throws -> [String: Any] {
        guard isAvailable else { throw DeepSeekError.api(availabilityHint) }
        let session = LanguageModelSession(instructions: system)
        let text: String
        do {
            text = try await session.respond(to: user).content
        } catch {
            throw DeepSeekError.api(error.localizedDescription)
        }
        // 端侧模型偶尔会包 ```json 围栏,剥掉后再解析
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekError.parse("返回格式异常")
        }
        if let error = payload["error"] as? String {
            throw DeepSeekError.parse(error)
        }
        return payload
    }
}
#endif
