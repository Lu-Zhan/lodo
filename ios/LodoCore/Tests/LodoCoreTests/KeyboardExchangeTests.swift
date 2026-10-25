import XCTest
@testable import LodoCore

final class KeyboardExchangeTests: XCTestCase {
    func testPrivateMemoriesStayOutOfSnapshot() {
        let plain = MemoryItem(kind: .text, title: "Wi-Fi 密码", tags: ["家"])
        XCTAssertTrue(KeyboardExchange.isShareable(plain))
        for tag in [MemoryItem.assetTagName, MemoryItem.healthTagName,
                    MemoryItem.checkupTagName, MemoryItem.weightReportTagName] {
            XCTAssertFalse(KeyboardExchange.isShareable(MemoryItem(kind: .text, title: "x", tags: [tag])), tag)
        }
    }

    func testObservationFormatMatchesPhone() {
        let date = Date(timeIntervalSince1970: 0)
        let snapshot = KeyboardExchange.Snapshot(memories: [
            .init(uuid: "A", title: "家里 Wi-Fi", summary: "密码", tags: [], excerpt: "lodo2026", createdAt: date),
            .init(uuid: "B", title: "车牌", summary: "", tags: [], excerpt: "京A12345", createdAt: date),
        ])
        // 命中的排前面,不够的按新近补齐(同手机/手表的 MemorySearch.rank)。
        XCTAssertEqual(KeyboardExchange.observation(for: "wifi 密码", in: snapshot).split(separator: "\n").first,
                       "「家里 Wi-Fi」lodo2026 [id:A]")
        XCTAssertEqual(KeyboardExchange.observation(for: "护照", in: KeyboardExchange.Snapshot()), "没有找到相关记忆内容")
    }

    func testMirrorCopiesAISettingsAndSkills() throws {
        let source = try XCTUnwrap(UserDefaults(suiteName: "kb-test-source"))
        let target = try XCTUnwrap(UserDefaults(suiteName: "kb-test-target"))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "kb-test-source")
            UserDefaults.standard.removePersistentDomain(forName: "kb-test-target")
        }
        source.set("DeepSeek Flash", forKey: AppSettings.aiProviderKey)
        source.set(false, forKey: "agentSkillEnabled.memory")
        target.set("stale", forKey: AppSettings.aiModelKey)
        KeyboardExchange.mirror(from: source, to: target)
        XCTAssertEqual(target.string(forKey: AppSettings.aiProviderKey), "DeepSeek Flash")
        XCTAssertEqual(target.object(forKey: "agentSkillEnabled.memory") as? Bool, false)
        XCTAssertNil(target.string(forKey: AppSettings.aiModelKey), "主 app 那边没设的要清掉")
    }
}
