import Foundation
import LodoIME
import LodoRerankerFFI

/// chinese-ime-lm 4M 重排器(权重 Apache-2.0,语料署名见 `attribution`,再分发必须保留)。
///
/// 上游会话缓存了上屏前缀和上一次按键的中间结果,所以一个键盘只建一个实例、串行调用;
/// 这里加锁只是防误用,不是为了并发。
public final class ModelReranker: Reranker, @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()
    /// 权重头里的语料署名。
    public let attribution: String

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let handle = data.withUnsafeBytes({ raw in
                  lodo_rr_load(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
              }) else { return nil }
        self.handle = handle
        if let c = lodo_rr_attribution(handle) {
            attribution = String(cString: c)
            lodo_rr_free_string(c)
        } else {
            attribution = ""
        }
    }

    /// 包里自带的 4M 权重。
    public static func bundled() -> ModelReranker? {
        Bundle.module.url(forResource: "pinyin-ime-reranker-4M", withExtension: "safetensors")
            .flatMap(ModelReranker.init(contentsOf:))
    }

    deinit { lodo_rr_free(handle) }

    public func best(context: String, candidates: [RerankCandidate]) -> Int? {
        guard candidates.count > 1 else { return nil }
        let texts = candidates.map { strdup($0.text) }
        defer { texts.forEach { free($0) } }
        let answers = candidates.map { UInt8($0.answersKey ? 1 : 0) }
        let trusted = candidates.map { UInt8($0.trustedDictionaryHit ? 1 : 0) }
        lock.lock()
        defer { lock.unlock() }
        let pick = texts.map { UnsafePointer($0) }.withUnsafeBufferPointer { textsPtr in
            lodo_rr_best_where(handle, context, textsPtr.baseAddress, answers, trusted, candidates.count)
        }
        return pick >= 0 ? Int(pick) : nil
    }
}
