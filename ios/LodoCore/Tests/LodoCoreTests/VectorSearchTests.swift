import XCTest
@testable import LodoCore

final class VectorSearchTests: XCTestCase {
    func testTopKOrdersByCosineSimilarity() {
        let a = UUID(), b = UUID(), c = UUID()
        let query: [Float] = [1, 0]
        let candidates: [(id: UUID, vector: [Float])] = [
            (a, [0, 1]),    // 垂直,相似度 0
            (b, [1, 0]),    // 完全同向,相似度 1
            (c, [1, 1]),    // 45 度,相似度 ~0.707
        ]
        XCTAssertEqual(VectorSearch.topK(query: query, candidates: candidates, k: 2), [b, c])
    }

    func testTopKRespectsLimit() {
        let ids = (0..<10).map { _ in UUID() }
        let candidates = ids.map { (id: $0, vector: [Float](repeating: 1, count: 4)) }
        let result = VectorSearch.topK(query: [1, 1, 1, 1], candidates: candidates, k: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testMismatchedDimensionsAreSkipped() {
        let matching = UUID(), mismatched = UUID()
        let candidates: [(id: UUID, vector: [Float])] = [
            (matching, [1, 0, 0]),
            (mismatched, [1, 0]),
        ]
        XCTAssertEqual(VectorSearch.topK(query: [1, 0, 0], candidates: candidates, k: 5), [matching])
    }

    func testEmptyQueryOrZeroKReturnsEmpty() {
        XCTAssertEqual(VectorSearch.topK(query: [], candidates: [(UUID(), [1, 0])], k: 5), [])
        XCTAssertEqual(VectorSearch.topK(query: [1, 0], candidates: [(UUID(), [1, 0])], k: 0), [])
    }

    func testCosineSimilarityZeroVectorIsNil() {
        XCTAssertNil(VectorSearch.cosineSimilarity([0, 0], [1, 1]))
    }

    func testCosineSimilarityIdenticalVectorsIsOne() {
        let similarity = try! XCTUnwrap(VectorSearch.cosineSimilarity([2, 0], [3, 0]))
        XCTAssertEqual(similarity, 1, accuracy: 0.0001)
    }
}
