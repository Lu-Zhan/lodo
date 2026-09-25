// watchOS 也带了 FoundationModels 这个框架,但里面的 API 要 watchOS 27 才有
// (`SystemLanguageModel` 在 watchOS 26 SDK 里直接标着 unavailable),光靠
// canImport 挡不住,Watch target 一编译就报一串 unavailable。Watch 侧本来就
// 永远走云端服务商分支,这里连同 os(watchOS) 一起排除掉。
#if canImport(FoundationModels) && !os(watchOS)
import Foundation
import FoundationModels

/// 苹果智能(Foundation Models)端侧推理:与云服务商同形的 JSON 传输层。
/// prompt 复用 DeepSeekClient 的全套指令(要求只返回 JSON),
/// 免 key、离线、数据不出设备;仅在支持 Apple Intelligence 的设备上可用。
/// Watch 上这个文件整体不编译(见文件头的门控),Watch 侧永远走云端服务商分支。
@available(iOS 26.0, macOS 26.0, *)
public enum FoundationModelsClient {
    /// 设备当前是否可用苹果智能。
    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// 面向设置页的可用性说明。
    public static var availabilityHint: String {
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
    public static func payload(system: String, user: String) async throws -> [String: Any] {
        guard isAvailable else { throw DeepSeekError.api(availabilityHint) }
        let session = LanguageModelSession(instructions: system)
        let text: String
        do {
            text = try await session.respond(to: user).content
        } catch {
            throw DeepSeekError.api(error.localizedDescription)
        }
        // 与云端共用的 JSON 容错解析(剥围栏、截取花括号区间)
        return try DeepSeekClient.decodePayload(from: text)
    }
}
#endif
