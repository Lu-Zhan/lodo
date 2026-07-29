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
            agentThreads: [BackupAgentThread(
                uuid: UUID(), title: "新对话", createdAt: Date(), updatedAt: Date())],
            agentMessages: [BackupAgentMessage(
                uuid: UUID(), threadUUID: UUID(), roleRaw: "user", kindRaw: "text",
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
        XCTAssertEqual(decoded.agentThreads[0].title, "新对话")
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

        let dto = original.backup
        let restored = TaskItem(title: "", remindAt: Date())
        dto.apply(to: restored)

        XCTAssertEqual(restored.uuid, original.uuid)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.durationMinutes, original.durationMinutes)
        XCTAssertEqual(restored.attachment?.title, "备注")
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

    func testAgentThreadAndMessageBackupAndApplyRoundTrip() {
        let thread = AgentThread()
        thread.title = "旅行计划"
        let message = AgentMessage(threadUUID: thread.uuid, role: .assistant, content: "好的")

        let threadDTO = thread.backup
        let restoredThread = AgentThread()
        threadDTO.apply(to: restoredThread)
        XCTAssertEqual(restoredThread.uuid, thread.uuid)
        XCTAssertEqual(restoredThread.title, "旅行计划")

        let messageDTO = message.backup
        let restoredMessage = AgentMessage(threadUUID: UUID(), role: .user, content: "")
        messageDTO.apply(to: restoredMessage)
        XCTAssertEqual(restoredMessage.uuid, message.uuid)
        XCTAssertEqual(restoredMessage.threadUUID, thread.uuid)
        XCTAssertEqual(restoredMessage.content, "好的")
        XCTAssertEqual(restoredMessage.role, .assistant)
    }
}
