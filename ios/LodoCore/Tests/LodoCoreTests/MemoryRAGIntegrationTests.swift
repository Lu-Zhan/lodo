import XCTest
@testable import LodoCore

#if (os(iOS) || os(macOS)) && canImport(NaturalLanguage)
/// 端到端验证方案里要解决的具体问题:旧的"整条内容前 400 字当摘录"会腰斩掉
/// 放在文档末尾的关键信息;新的分片 + 语义检索应该能命中含关键信息的那个 chunk,
/// 即使问题的用词和原文不完全一样(同义改述,不是字面重合)。
/// 只验证检索这一段(真实 embedding、真实分片、真实相似度排序),不发 DeepSeek
/// 请求——那一步的正确性不属于这次改动的范围,维持原样。
final class MemoryRAGIntegrationTests: XCTestCase {
    func testSemanticRetrievalFindsFactBeyondOldTruncationLimit() async throws {
        // 填充材料把"关键信息"挤到 400 字之后(旧摘录上限),模拟长文档。
        let filler = String(repeating: "今天天气不错,适合出门散步。", count: 60)
        XCTAssertGreaterThan(filler.count, MemorySearch.maxExcerptChars)
        let text = filler + "\n\n重要提示:门禁系统的备用密码是 7391,只在主密码失效时使用。"

        let provider = OnDeviceEmbeddingProvider()
        let chunks = MemoryChunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1, "材料应该被切成多片,不然测试没有意义")

        let vectors: [[Float]]
        do {
            vectors = try await provider.embed(chunks)
        } catch {
            throw XCTSkip("端上语义模型当前不可用:\(error)")
        }

        let ids = chunks.indices.map { _ in UUID() }
        let candidates = zip(ids, vectors).map { (id: $0, vector: $1) }

        // 问题用词跟原文不完全一样("备用密码"→"第二个密码"),纯关键词检索未必能命中,
        // 语义检索应该能。
        let questionVectors = try await provider.embed(["门禁的第二个密码是多少"])
        let topChunkIDs = VectorSearch.topK(query: questionVectors[0], candidates: candidates, k: 1)

        guard let topID = topChunkIDs.first, let index = ids.firstIndex(of: topID) else {
            XCTFail("语义检索没有返回任何结果")
            return
        }
        XCTAssertTrue(chunks[index].contains("7391"),
                      "top-1 chunk 应该是含备用密码的那一片,实际命中:\(chunks[index].prefix(30))…")
    }
}
#endif
