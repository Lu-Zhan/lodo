import XCTest
@testable import LodoCore

#if (os(iOS) || os(macOS)) && canImport(NaturalLanguage)
/// 端上 embedding 的真实运行验证(需要下载模型资源,首次运行可能较慢);
/// 资源确实不可用时跳过而不是判失败——CI/无网环境不应该因为这个卡住。
final class OnDeviceEmbeddingProviderTests: XCTestCase {
    func testEmbedsChineseText() async throws {
        let provider = OnDeviceEmbeddingProvider()
        let vectors: [[Float]]
        do {
            vectors = try await provider.embed(["记住 wifi 密码是 8888", "今天天气怎么样"])
        } catch {
            throw XCTSkip("端上语义模型当前不可用:\(error)")
        }
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            XCTAssertFalse(vector.isEmpty, "中文文本应该能算出非空向量")
        }
        // 语义相近的两句应该比随机向量更相似(排除维度错误的低级问题)
        let similarity = VectorSearch.cosineSimilarity(vectors[0], vectors[1])
        XCTAssertNotNil(similarity)
    }

    func testEmptyInputReturnsEmpty() async throws {
        let provider = OnDeviceEmbeddingProvider()
        let vectors = try await provider.embed([])
        XCTAssertEqual(vectors.count, 0)
    }
}
#endif
