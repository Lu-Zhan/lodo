import Foundation
import LodoIME

/// 把拼音解码(词图 + Viterbi + 模型重排)挪到一条后台串行队列上,按键不再等它。
///
/// 队列上有一份**自己的** `PinyinEngine`(和主线程那份共用只读的词库与带锁的重排器),只在这条队列上碰;
/// 主线程那份照旧负责组合态和用户词学习,学完把用户词快照发过来(`setUserDictionary`)。
/// 命令都排在同一条串行队列上,所以「学了词 → 下一次解码」的先后不会乱。
public final class BackgroundDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lodo.ime.decode", qos: .userInitiated)
    private let engine: PinyinEngine

    public init(lexicon: Lexicon, userDictionary: UserDictionary, fuzzy: FuzzyOptions = []) {
        engine = PinyinEngine(lexicon: lexicon, userDictionary: userDictionary, fuzzy: fuzzy)
    }

    /// 后台解一次,结果回到主线程。
    public func decode(_ input: String, context: String, completion: @escaping (PinyinEngine.Result) -> Void) {
        queue.async { [engine] in
            let result = engine.candidates(for: input, context: context)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 当场要结果(上屏那一下屏幕上的候选已经过时了):排在已经发出去的解码后面,同步等它。
    public func decodeNow(_ input: String, context: String, limit: Int = 60) -> PinyinEngine.Result {
        queue.sync { engine.candidates(for: input, context: context, limit: limit) }
    }

    public func setUserDictionary(_ dictionary: UserDictionary) {
        queue.async { [engine] in engine.userDictionary = dictionary }
    }

    public func setFuzzy(_ fuzzy: FuzzyOptions) {
        queue.async { [engine] in if engine.fuzzy != fuzzy { engine.fuzzy = fuzzy } }
    }

    public func setReranker(_ reranker: Reranker?) {
        queue.async { [engine] in engine.reranker = reranker }
    }
}
