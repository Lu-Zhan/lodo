// watchOS 不带 NLContextualEmbedding(语义检索也用不上,Watch 没有记忆功能),
// 显式只在 iOS/macOS 上编译,不依赖 canImport 对具体符号可用性的猜测。
#if (os(iOS) || os(macOS)) && canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// 端上语义向量:NLContextualEmbedding(iOS 17/macOS 14 随系统自带,免费离线)。
/// 模型资源没下载好,或当前系统对目标语言没有可用模型时,统一按 unavailable
/// 处理——调用方退回云端 provider 或纯关键词检索,不阻塞记忆功能本身。
public struct OnDeviceEmbeddingProvider: EmbeddingProvider {
    public init() {}

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let language = Self.dominantLanguage(of: texts)
        guard let embedder = NLContextualEmbedding(language: language)
            ?? NLContextualEmbedding(language: .english) else {
            throw EmbeddingError.unavailable
        }
        try await Self.ensureAssets(embedder)
        try embedder.load()
        return try texts.map { try Self.vector(for: $0, using: embedder, language: language) }
    }

    private static func dominantLanguage(of texts: [String]) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        return recognizer.dominantLanguage ?? .simplifiedChinese
    }

    private static func ensureAssets(_ embedder: NLContextualEmbedding) async throws {
        if embedder.hasAvailableAssets { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            embedder.requestAssets { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if result == .available {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: EmbeddingError.unavailable)
                }
            }
        }
    }

    /// 句向量 = 全部 token 向量取平均(NLContextualEmbedding 只给 token 级向量)。
    private static func vector(
        for text: String, using embedder: NLContextualEmbedding, language: NLLanguage
    ) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let result = try embedder.embeddingResult(for: trimmed, language: language)
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            if sum.isEmpty { sum = [Double](repeating: 0, count: vector.count) }
            for i in 0..<vector.count { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return [] }
        return sum.map { Float($0 / Double(count)) }
    }
}
#endif
