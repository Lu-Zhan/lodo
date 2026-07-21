import Foundation

/// 语义向量来源的统一接口;端上/云端两种实现见 OnDeviceEmbeddingProvider(app 层,
/// 需要 NaturalLanguage 框架)与 CloudEmbeddingProvider(Phase 2)。
/// 定义在 LodoCore 是为了 VectorSearch 的检索逻辑能脱离具体实现单测。
public protocol EmbeddingProvider {
    /// 批量算向量,失败(不可用/请求出错)整批抛错,调用方负责降级。
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum EmbeddingError: LocalizedError {
    /// 端上模型资源未就绪、云端未配置支持 embedding 的服务商等——都算"这条路走不通",
    /// 调用方应该尝试下一个 provider 或退回关键词检索,不是把错误展示给用户。
    case unavailable
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "语义检索不可用"
        case .api(let m): return "语义检索请求失败:\(m)"
        }
    }
}

/// 余弦相似度检索,纯函数:不依赖任何 provider,可用固定向量直接单测。
public enum VectorSearch {
    /// candidates 为空、或与 query 维度不一致的候选会被跳过(不同 provider/模型算出的
    /// 向量维度不同,混用没有意义,宁可漏检也不要算出错误的相似度)。
    public static func topK(
        query: [Float], candidates: [(id: UUID, vector: [Float])], k: Int
    ) -> [UUID] {
        guard !query.isEmpty, k > 0 else { return [] }
        let scored = candidates.compactMap { candidate -> (id: UUID, score: Float)? in
            guard candidate.vector.count == query.count else { return nil }
            guard let score = cosineSimilarity(query, candidate.vector) else { return nil }
            return (candidate.id, score)
        }
        return scored.sorted { $0.score > $1.score }.prefix(k).map(\.id)
    }

    /// 两个向量之一是零向量时相似度无意义,返回 nil。
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return nil }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
