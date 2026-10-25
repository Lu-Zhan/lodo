import Foundation

/// 交给重排器的一条候选,两个布尔量的含义照 chinese-ime-lm `CandidateFacts`:
/// - `answersKey`:这条吃满了当前整个键(不是前缀、也不是越过键的补全)。
///   注意不是"和首选等长":xian 读成「现」和「西安」都吃满整个键。
/// - `trustedDictionaryHit`:词典整键命中且没经过纠错/模糊音。这种候选带着词频证据,
///   实测让模型覆盖它在任何权重下都掉分,所以首选是它时根本不调重排器。
public struct RerankCandidate: Sendable {
    public let text: String
    public let answersKey: Bool
    public let trustedDictionaryHit: Bool

    public init(text: String, answersKey: Bool, trustedDictionaryHit: Bool) {
        self.text = text
        self.answersKey = answersKey
        self.trustedDictionaryHit = trustedDictionaryHit
    }
}

public protocol Reranker: Sendable {
    /// 返回应当排第一的下标;nil = 不改。`context` 是光标前已经上屏的文字。
    func best(context: String, candidates: [RerankCandidate]) -> Int?
}
