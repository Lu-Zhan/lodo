import XCTest
@testable import LodoCore

/// 家人体检档案共享的纯逻辑:zone 名、记录 ↔ 模型、收到的报告不进健康分析。
final class SharedHealthSyncTests: XCTestCase {

    func testZoneNameRoundTripAndKind() {
        let id = UUID()
        let name = SharedHealthMapping.zoneName(for: id)
        XCTAssertEqual(SharedZoneKind(zoneName: name), .health)
        XCTAssertEqual(SharedZoneKind.containerUUID(fromZoneName: name), id)
        XCTAssertEqual(SharedHealthMapping.profileUUID(fromZoneName: name), id)
        XCTAssertNil(SharedHealthMapping.profileUUID(fromZoneName: SharedTripMapping.zoneName(for: id)))
        // 别的前缀不受影响。
        XCTAssertEqual(SharedZoneKind(zoneName: SharedTripMapping.zoneName(for: id)), .trip)
    }

    func testProfileRoundTrip() {
        let profile = HealthProfile(name: "妈妈", relation: "母亲", birthday: Date(timeIntervalSince1970: 0),
                                    notes: "青霉素过敏")
        let snapshot = SharedHealthMapping.snapshot(of: profile)
        XCTAssertEqual(snapshot.type, .healthProfile)
        let copy = HealthProfile(uuid: profile.uuid, name: "")
        SharedHealthMapping.apply(snapshot.fields, to: copy)
        XCTAssertEqual(SharedHealthMapping.snapshot(of: copy), snapshot)
        // 共享身份不进记录。
        XCTAssertNil(snapshot.fields["shareRoleRaw"])
    }

    /// 收到的报告挂在这位家人名下、只打「体检报告」(不打「健康」,不进健康分析),
    /// 对方给的不安全文件路径丢掉。
    func testReceivedReportIsFamilyOnlyAndPathsSanitized() {
        let profileID = UUID()
        let source = MemoryItem(kind: .pdf, title: "2026 年体检",
                                tags: [MemoryItem.checkupTagName, MemoryItem.healthTagName],
                                status: .ready)
        source.checkupDate = Date(timeIntervalSince1970: 1_000)
        source.checkupInstitution = "某医院"
        source.relativeFilePath = "Memory/a.pdf"
        source.attachmentRelativePaths = ["Memory/b.jpg", "../lodo.store"]
        var fields = SharedHealthMapping.snapshot(ofReport: source).fields
        fields["relativeFilePath"] = .string("lodo.store")

        let received = MemoryItem(kind: .text)
        SharedHealthMapping.applyReport(fields, to: received, profileUUID: profileID)
        XCTAssertEqual(received.checkupProfileUUID, profileID)
        XCTAssertEqual(received.tags, [MemoryItem.checkupTagName])
        XCTAssertFalse(received.isHealth)
        XCTAssertEqual(received.checkupInstitution, "某医院")
        XCTAssertEqual(received.checkupDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(received.relativeFilePath)
        XCTAssertEqual(received.attachmentRelativePaths, ["Memory/b.jpg"])
    }

    func testEntryRoundTrip() {
        let profileID = UUID()
        let entry = CheckupEntry(reportUUID: UUID(), profileUUID: profileID, kind: .item, category: "血脂",
                                 name: "总胆固醇", value: "5.8", unit: "mmol/L", referenceRange: "<5.2",
                                 flag: .high, conclusion: "", advice: "低脂饮食",
                                 date: Date(timeIntervalSince1970: 2_000), sortIndex: 3)
        let snapshot = SharedHealthMapping.snapshot(of: entry)
        let copy = CheckupEntry(uuid: entry.uuid, reportUUID: UUID(), date: .now)
        SharedHealthMapping.apply(snapshot.fields, to: copy, profileUUID: profileID)
        XCTAssertEqual(copy.reportUUID, entry.reportUUID)
        XCTAssertEqual(copy.profileUUID, profileID)
        XCTAssertEqual(copy.flag, .high)
        XCTAssertEqual(SharedHealthMapping.snapshot(of: copy), snapshot)
    }
}
