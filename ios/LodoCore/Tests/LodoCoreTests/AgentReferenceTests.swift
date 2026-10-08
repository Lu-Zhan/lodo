import XCTest
@testable import LodoCore

final class AgentReferenceTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testPromptBlockCarriesKindTitleAndID() {
        let reference = AgentReference(kind: .trip, id: id, title: "北海道")
        XCTAssertEqual(
            reference.promptBlock(body: "  第 1 天:札幌\n"),
            "[引用 · 旅行:北海道] [id:11111111-2222-3333-4444-555555555555]\n第 1 天:札幌")
        XCTAssertEqual(
            reference.promptBlock(body: " "),
            "[引用 · 旅行:北海道] [id:11111111-2222-3333-4444-555555555555]")
    }

    func testEncodeDecodeRoundTrip() {
        let references = [AgentReference(kind: .asset, id: id, title: "房子"),
                          AgentReference(kind: .news, id: UUID(), title: "头条")]
        XCTAssertNil(AgentReference.encode([]))
        XCTAssertEqual(AgentReference.decode(AgentReference.encode(references)), references)
        XCTAssertEqual(AgentReference.decode(nil), [])
        XCTAssertEqual(AgentReference.decode(Data("garbage".utf8)), [])
    }

    /// 存储值是持久化字符串,别改。
    func testKindRawValuesAreStable() {
        XCTAssertEqual(AgentReferenceKind.allCases.map(\.rawValue),
                       ["task", "countdown", "trip", "asset", "finance", "contact", "menu", "news"])
    }

    func testBackupMessageKeepsReferencesAndToleratesOldFormat() throws {
        let message = BackupAgentMessage(
            uuid: id, roleRaw: "user", kindRaw: "text", content: "看看这趟",
            relatedTitles: [], attachmentMemoryUUIDs: [],
            references: [AgentReference(kind: .trip, id: id, title: "北海道")], createdAt: Date())
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(BackupAgentMessage.self, from: data).references,
                       message.references)

        // 老备份没有 references 这个 key。
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "references")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(BackupAgentMessage.self, from: old).references, [])
    }
}
