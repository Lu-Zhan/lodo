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
    private let fastQueue = DispatchQueue(label: "com.lodo.ime.fast", qos: .userInitiated)
    private let fastEngine: PinyinEngine
    // 上屏只需要基础候选,不能排在模型重排后面。
    private let commitQueue = DispatchQueue(label: "com.lodo.ime.commit", qos: .userInitiated)
    private let commitEngine: PinyinEngine

    public init(lexicon: Lexicon, userDictionary: UserDictionary, fuzzy: FuzzyOptions = []) {
        engine = PinyinEngine(lexicon: lexicon, userDictionary: userDictionary, fuzzy: fuzzy)
        fastEngine = PinyinEngine(lexicon: lexicon, userDictionary: userDictionary, fuzzy: fuzzy)
        commitEngine = PinyinEngine(lexicon: lexicon, userDictionary: userDictionary, fuzzy: fuzzy)
    }

    /// 后台解一次,结果回到主线程。
    public func decode(_ input: String, context: String,
                       completion: @escaping (PinyinEngine.Result, Bool) -> Void) {
        fastQueue.async { [fastEngine, queue, engine] in
            let base = fastEngine.candidates(for: input, context: context, rerank: false)
            DispatchQueue.main.async { completion(base, false) }
            guard base.candidates.count > 1, base.candidates.first?.trustedDictionaryHit != true else { return }
            queue.async {
                let improved = engine.candidates(for: input, context: context)
                DispatchQueue.main.async { completion(improved, true) }
            }
        }
    }

    /// 候选尚未跟上输入时,异步求上屏用的基础候选。与模型队列隔离。
    public func decodeForCommit(_ input: String, context: String, completion: @escaping (PinyinEngine.Result) -> Void) {
        commitQueue.async { [commitEngine] in
            let result = commitEngine.candidates(for: input, context: context, rerank: false)
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func setUserDictionary(_ dictionary: UserDictionary) {
        queue.async { [engine] in engine.userDictionary = dictionary }
        fastQueue.async { [fastEngine] in fastEngine.userDictionary = dictionary }
        commitQueue.async { [commitEngine] in commitEngine.userDictionary = dictionary }
    }

    public func setPersonalDictionary(_ dictionary: PersonalDictionary?) {
        queue.async { [engine] in engine.personalDictionary = dictionary }
        fastQueue.async { [fastEngine] in fastEngine.personalDictionary = dictionary }
        commitQueue.async { [commitEngine] in commitEngine.personalDictionary = dictionary }
    }

    public func setFuzzy(_ fuzzy: FuzzyOptions) {
        queue.async { [engine] in if engine.fuzzy != fuzzy { engine.fuzzy = fuzzy } }
        fastQueue.async { [fastEngine] in if fastEngine.fuzzy != fuzzy { fastEngine.fuzzy = fuzzy } }
        commitQueue.async { [commitEngine] in if commitEngine.fuzzy != fuzzy { commitEngine.fuzzy = fuzzy } }
    }

    public func setCorrectionEnabled(_ enabled: Bool) {
        queue.async { [engine] in if engine.correctionEnabled != enabled { engine.correctionEnabled = enabled } }
        fastQueue.async { [fastEngine] in if fastEngine.correctionEnabled != enabled { fastEngine.correctionEnabled = enabled } }
        commitQueue.async { [commitEngine] in if commitEngine.correctionEnabled != enabled { commitEngine.correctionEnabled = enabled } }
    }

    public func setReranker(_ reranker: Reranker?) {
        queue.async { [engine] in engine.reranker = reranker }
    }
}
