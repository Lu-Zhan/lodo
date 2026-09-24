import XCTest
@testable import LodoCore

/// BackupData 的 Codable 往返 + 模型互转(backup/apply)测试。
final class BackupDataTests: XCTestCase {
    func testBackupPayloadRoundTrip() throws {
        let payload = BackupPayload(
            tasks: [BackupTask(
                uuid: UUID(), title: "开会", remindAt: Date(), durationMinutes: 30,
                allDay: false, repeatTypeRaw: "none", repeatDays: [], repeatTimes: [],
                statusRaw: "pending", phaseRaw: "start", nextRemindAt: Date(),
                createdAt: Date(), doneAt: nil, ekIdentifier: nil, attachmentKindRaw: nil,
                attachmentTitle: nil, attachmentSummary: nil, attachmentText: nil,
                attachmentURLString: nil, attachmentFileName: nil)],
            memoryItems: [BackupMemoryItem(
                uuid: UUID(), kindRaw: "text", title: "标题", summary: "摘要", tags: ["标签"],
                sourceText: "原文", urlString: nil, originalFileName: nil,
                relativeFilePath: nil, statusRaw: "ready", createdAt: Date())],
            memoryTags: [BackupMemoryTag(name: "工作", createdAt: Date())],
            agentMessages: [BackupAgentMessage(
                uuid: UUID(), roleRaw: "user", kindRaw: "text",
                content: "你好", relatedTitles: [],
                attachmentMemoryUUIDs: [], createdAt: Date())],
            skillOverrides: [BackupSkillOverride(id: "agent", content: "自定义总则")],
            settings: BackupSettings(
                snoozeMinutes: 15, allDayTime: "09:00", digestEnabled: true,
                digestTime: "21:00", digestTimes: "09:00,21:00", digestRepeatType: "daily",
                digestDays: "0,1,2,3,4", hapticsEnabled: true, insightEnabled: true,
                agentSilenceTimeoutSeconds: 3,
                agentPersonaStyle: "默认", agentPersonaCustom: "", aiProvider: "DeepSeek",
                aiModel: "", aiCustomEndpoint: "", icloudSyncEnabled: true))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(BackupPayload.self, from: data)

        XCTAssertEqual(decoded.tasks.count, 1)
        XCTAssertEqual(decoded.tasks[0].title, "开会")
        XCTAssertEqual(decoded.memoryItems[0].tags, ["标签"])
        XCTAssertEqual(decoded.memoryTags[0].name, "工作")
        XCTAssertEqual(decoded.agentMessages[0].content, "你好")
        XCTAssertEqual(decoded.skillOverrides[0].content, "自定义总则")
        XCTAssertEqual(decoded.settings.snoozeMinutes, 15)
        XCTAssertEqual(decoded.settings.aiProvider, "DeepSeek")
    }

    func testManifestRoundTrip() throws {
        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion, exportedAt: Date(),
            appVersion: "1.0", taskCount: 3, memoryCount: 2, memoryTagCount: 1,
            agentThreadCount: 1, agentMessageCount: 4, skillOverrideCount: 0)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: data)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.taskCount, 3)
        XCTAssertEqual(decoded.agentMessageCount, 4)
    }

    // MARK: - 模型 ↔ DTO 互转(backup / apply)

    func testTaskItemBackupAndApplyRoundTrip() {
        let original = TaskItem(title: "开会", remindAt: Date(), durationMinutes: 30)
        original.attachment = TaskAttachment(
            kind: .text, title: "备注", summary: "摘要", text: "正文", urlString: nil,
            originalFileName: nil)
        original.ignoreStreak = 3

        let dto = original.backup
        let restored = TaskItem(title: "", remindAt: Date())
        dto.apply(to: restored)

        XCTAssertEqual(restored.uuid, original.uuid)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.durationMinutes, original.durationMinutes)
        XCTAssertEqual(restored.attachment?.title, "备注")
        XCTAssertEqual(restored.ignoreStreak, 3)
    }

    func testTaskItemWithProjectBackupAndApplyRoundTrip() {
        let original = TaskItem(title: "写周报", remindAt: Date(), project: "工作")

        let dto = original.backup
        let restored = TaskItem(title: "", remindAt: Date())
        dto.apply(to: restored)

        XCTAssertEqual(restored.project, "工作")
    }

    func testMemoryItemBackupAndApplyRoundTrip() {
        let original = MemoryItem(kind: .link, title: "标题", urlString: "https://a.com")
        let dto = original.backup
        let restored = MemoryItem(kind: .text)
        dto.apply(to: restored)

        XCTAssertEqual(restored.uuid, original.uuid)
        XCTAssertEqual(restored.kind, .link)
        XCTAssertEqual(restored.urlString, "https://a.com")
    }

    func testAssetMemoryItemBackupAndApplyRoundTrip() {
        let original = MemoryItem(
            kind: .text, title: "自住房产", tags: [MemoryItem.assetTagName],
            assetValue: 3_000_000, assetCurrency: "CNY",
            assetLiability: 1_000_000, assetInterestRate: 4.5)
        let dto = original.backup
        let restored = MemoryItem(kind: .text)
        dto.apply(to: restored)

        XCTAssertTrue(restored.isAsset)
        XCTAssertEqual(restored.assetValue, 3_000_000)
        XCTAssertEqual(restored.assetCurrency, "CNY")
        XCTAssertEqual(restored.assetLiability, 1_000_000)
        XCTAssertEqual(restored.assetInterestRate, 4.5)
    }

    func testContactMemoryItemBackupAndApplyRoundTrip() {
        let birthday = Date(timeIntervalSince1970: 0)
        let original = MemoryItem(
            kind: .text, title: "张三", tags: [MemoryItem.contactTagName],
            contactNickname: "小张", contactPhone: "13800000000", contactEmail: "a@b.com",
            contactBirthday: birthday, contactPreferences: "咖啡",
            contactAvatarRelativePath: "Contacts/a-avatar.jpg",
            attachmentRelativePaths: ["Contacts/x.pdf", "Contacts/y.png"])
        let dto = original.backup
        let restored = MemoryItem(kind: .text)
        dto.apply(to: restored)

        XCTAssertTrue(restored.isContact)
        XCTAssertEqual(restored.contactNickname, "小张")
        XCTAssertEqual(restored.contactPhone, "13800000000")
        XCTAssertEqual(restored.contactEmail, "a@b.com")
        XCTAssertEqual(restored.contactBirthday, birthday)
        XCTAssertEqual(restored.contactPreferences, "咖啡")
        XCTAssertEqual(restored.contactAvatarRelativePath, "Contacts/a-avatar.jpg")
        XCTAssertEqual(restored.attachmentRelativePaths, ["Contacts/x.pdf", "Contacts/y.png"])
    }

    func testContactRelationshipBackupAndApplyRoundTrip() {
        let a = UUID()
        let b = UUID()
        let original = ContactRelationship(memoryUUIDA: a, memoryUUIDB: b, label: "同事")
        let dto = original.backup
        let restored = ContactRelationship(memoryUUIDA: UUID(), memoryUUIDB: UUID(), label: "")
        dto.apply(to: restored)

        XCTAssertEqual(restored.uuid, original.uuid)
        XCTAssertEqual(restored.memoryUUIDA, a)
        XCTAssertEqual(restored.memoryUUIDB, b)
        XCTAssertEqual(restored.label, "同事")
    }

    /// 老格式备份 JSON 没有 attachmentRelativePaths/contactRelationships 这些新 key,
    /// 必须仍能正常解码(靠属性声明处的默认值兜底),不能因为升级就打不开旧备份。
    func testOldFormatBackupPayloadDecodesWithoutNewKeys() throws {
        let oldFormatJSON = """
        {
          "tasks": [
            {
              "uuid": "\(UUID().uuidString)",
              "title": "老待办",
              "remindAt": 0,
              "durationMinutes": 0,
              "allDay": false,
              "repeatTypeRaw": "none",
              "repeatDays": [],
              "repeatTimes": [],
              "statusRaw": "pending",
              "phaseRaw": "start",
              "nextRemindAt": 0,
              "createdAt": 0
            }
          ],
          "memoryItems": [
            {
              "uuid": "\(UUID().uuidString)",
              "kindRaw": "text",
              "title": "老记录",
              "summary": "",
              "tags": [],
              "sourceText": "",
              "statusRaw": "ready",
              "createdAt": 0
            }
          ],
          "memoryTags": [],
          "agentThreads": [
            {
              "uuid": "\(UUID().uuidString)",
              "title": "老对话", "createdAt": 0, "updatedAt": 0
            }
          ],
          "agentMessages": [
            {
              "uuid": "\(UUID().uuidString)",
              "threadUUID": "\(UUID().uuidString)",
              "roleRaw": "user", "kindRaw": "text", "content": "老消息",
              "relatedTitles": [], "attachmentMemoryUUIDs": [], "createdAt": 0
            }
          ],
          "skillOverrides": [],
          "settings": {
            "snoozeMinutes": 15, "allDayTime": "09:00", "digestEnabled": true,
            "digestTime": "21:00", "digestTimes": "09:00,21:00", "digestRepeatType": "daily",
            "digestDays": "0,1,2,3,4", "hapticsEnabled": true, "insightEnabled": true,
            "agentSilenceTimeoutSeconds": 3, "agentPersonaStyle": "默认",
            "agentPersonaCustom": "", "aiProvider": "DeepSeek", "aiModel": "",
            "aiCustomEndpoint": "", "icloudSyncEnabled": true, "thinkingLevel": "medium"
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            BackupPayload.self, from: Data(oldFormatJSON.utf8))
        XCTAssertEqual(decoded.tasks[0].title, "老待办")
        XCTAssertEqual(decoded.tasks[0].ignoreStreak, 0)
        XCTAssertEqual(decoded.memoryItems[0].title, "老记录")
        XCTAssertEqual(decoded.memoryItems[0].attachmentRelativePaths, [])
        XCTAssertNil(decoded.memoryItems[0].contactNickname)
        XCTAssertTrue(decoded.contactRelationships.isEmpty)
        // 老备份里的 agentThreads 整段被忽略(没有对应的模型可落),
        // 同一份里的消息照常恢复 —— threadUUID 那个 key 多出来也不影响解码。
        XCTAssertTrue(decoded.agentThreads.isEmpty)
        XCTAssertEqual(decoded.agentMessages[0].content, "老消息")
        XCTAssertEqual(decoded.settings.sttEngine, "qwenASR")
        XCTAssertTrue(decoded.settings.useBuiltInSTTKey)
        XCTAssertTrue(decoded.settings.quietHoursEnabled)
        XCTAssertEqual(decoded.settings.quietHoursStart, "22:00")
        XCTAssertEqual(decoded.settings.quietHoursEnd, "08:00")
    }

    func testAgentMessageBackupAndApplyRoundTrip() {
        let message = AgentMessage(role: .assistant, content: "好的")

        let messageDTO = message.backup
        let restoredMessage = AgentMessage(role: .user, content: "")
        // formatVersion 先按老库的存量行摆成 0,验证 apply 会把它抬回 1——
        // 留在 0 的话下次启动会被 AgentHistoryMigration 当成老分段对话删掉。
        restoredMessage.formatVersion = 0
        messageDTO.apply(to: restoredMessage)
        XCTAssertEqual(restoredMessage.uuid, message.uuid)
        XCTAssertEqual(restoredMessage.content, "好的")
        XCTAssertEqual(restoredMessage.roleRaw, "assistant")
        XCTAssertEqual(restoredMessage.formatVersion, 1)
    }

    /// 退役的 agentThreads / threadUUID 仍要写进新备份:老版本 app 里这两个 key
    /// 是必需的,不写会让那边整条 decode 失败。别"顺手清理"掉。
    func testEncodedPayloadStillCarriesRetiredThreadKeys() throws {
        let payload = BackupPayload(
            tasks: [], memoryItems: [], memoryTags: [],
            agentMessages: [BackupAgentMessage(
                uuid: UUID(), roleRaw: "user", kindRaw: "text", content: "你好",
                relatedTitles: [], attachmentMemoryUUIDs: [], createdAt: Date())],
            skillOverrides: [],
            settings: BackupSettings(
                snoozeMinutes: 15, allDayTime: "09:00", digestEnabled: true,
                digestTime: "21:00", digestTimes: "09:00", digestRepeatType: "daily",
                digestDays: "0", hapticsEnabled: true, insightEnabled: true,
                agentSilenceTimeoutSeconds: 3,
                agentPersonaStyle: "默认", agentPersonaCustom: "", aiProvider: "DeepSeek",
                aiModel: "", aiCustomEndpoint: "", icloudSyncEnabled: true))
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)) as! [String: Any]
        XCTAssertNotNil(json["agentThreads"] as? [Any])
        XCTAssertEqual((json["agentThreads"] as? [Any])?.count, 0)
        let messages = json["agentMessages"] as! [[String: Any]]
        XCTAssertNotNil(messages[0]["threadUUID"])
    }
}
