import Foundation
import SwiftData
import LodoCore

/// 设置页"导出/导入备份"的编排逻辑:ZipArchive/BackupData 是不碰平台专属 API 的
/// 纯逻辑(在 LodoCore),这里负责把它们和 ModelContext 查询、App Group 附件文件、
/// AgentSkillStore 覆盖、UserDefaults 设置接起来——与 MemoryPipeline/WidgetBridge
/// 已经是这个分层同一个思路。与 iCloud/CloudKit 同步完全独立、互不影响,
/// 是并存的第二条持久化路径。
@MainActor
enum BackupManager {
    enum MergeStrategy {
        /// 按 uuid 更新已存在的、插入新的,不删除设备上有备份里没有的记录。
        case merge
        /// 先清空设备上所有待办/记忆/AI 对话,再整体导入备份内容。
        case replace
    }

    enum BackupError: LocalizedError {
        case invalidZip

        var errorDescription: String? {
            switch self {
            case .invalidZip: return "无法识别这份备份文件"
            }
        }
    }

    private static let manifestPath = "manifest.json"
    private static let dataPath = "data.json"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - 导出

    /// 生成一份包含待办、记忆(含附件)、AI 对话、自定义 skill、设置的 zip,
    /// 落在临时目录,调用方用 ShareLink 分享出去。不含 API Key。
    static func export(context: ModelContext) throws -> URL {
        let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? [])
        let memoryItems = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? [])
        let memoryTags = ((try? context.fetch(FetchDescriptor<MemoryTag>())) ?? [])
        let agentThreads = ((try? context.fetch(FetchDescriptor<AgentThread>())) ?? [])
        let agentMessages = ((try? context.fetch(FetchDescriptor<AgentMessage>())) ?? [])
        let skillOverrides = AgentSkillID.allCases
            .filter { AgentSkillStore.isCustomized($0) }
            .map { BackupSkillOverride(id: $0.rawValue, content: AgentSkillStore.content(for: $0)) }

        let payload = BackupPayload(
            tasks: tasks.map { $0.backup },
            memoryItems: memoryItems.map { $0.backup },
            memoryTags: memoryTags.map { $0.backup },
            agentThreads: agentThreads.map { $0.backup },
            agentMessages: agentMessages.map { $0.backup },
            skillOverrides: skillOverrides,
            settings: currentSettings())

        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            taskCount: tasks.count, memoryCount: memoryItems.count,
            memoryTagCount: memoryTags.count, agentThreadCount: agentThreads.count,
            agentMessageCount: agentMessages.count, skillOverrideCount: skillOverrides.count)

        var entries: [ZipArchive.Entry] = [
            ZipArchive.Entry(path: manifestPath, data: try encoder.encode(manifest)),
            ZipArchive.Entry(path: dataPath, data: try encoder.encode(payload)),
        ]
        for item in memoryItems {
            guard let fileURL = MemoryPipeline.fileURL(of: item),
                  let data = try? Data(contentsOf: fileURL) else { continue }
            entries.append(ZipArchive.Entry(path: "files/\(fileURL.lastPathComponent)", data: data))
        }

        let zipData = ZipArchive.write(entries)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "lodo-backup-\(Int(Date().timeIntervalSince1970)).zip")
        try zipData.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 导入预览

    /// 只读 manifest.json,给导入确认页展示"导出于 X · 包含 N 条待办…"用,
    /// 不需要先解出整份 data.json。
    static func preview(zipURL: URL) throws -> BackupManifest {
        let entries = try ZipArchive.read(try Data(contentsOf: zipURL))
        guard let entry = entries.first(where: { $0.path == manifestPath }) else {
            throw BackupError.invalidZip
        }
        return try decoder.decode(BackupManifest.self, from: entry.data)
    }

    // MARK: - 导入提交

    static func commit(zipURL: URL, strategy: MergeStrategy, context: ModelContext) throws {
        let entries = try ZipArchive.read(try Data(contentsOf: zipURL))
        guard let dataEntry = entries.first(where: { $0.path == dataPath }) else {
            throw BackupError.invalidZip
        }
        let payload = try decoder.decode(BackupPayload.self, from: dataEntry.data)

        if strategy == .replace {
            wipeAllData(context: context)
        }

        for dto in payload.tasks {
            let uuid = dto.uuid
            let existing = ((try? context.fetch(FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.uuid == uuid }))) ?? []).first
            let item = existing ?? {
                let created = TaskItem(title: dto.title, remindAt: dto.remindAt)
                context.insert(created)
                return created
            }()
            dto.apply(to: item)
        }

        for dto in payload.memoryItems {
            let uuid = dto.uuid
            let existing = ((try? context.fetch(FetchDescriptor<MemoryItem>(
                predicate: #Predicate { $0.uuid == uuid }))) ?? []).first
            let item = existing ?? {
                let created = MemoryItem(kind: .text)
                context.insert(created)
                return created
            }()
            dto.apply(to: item)
            restoreFile(for: dto, entries: entries)
        }

        for dto in payload.memoryTags {
            let name = dto.name
            let existing = ((try? context.fetch(FetchDescriptor<MemoryTag>(
                predicate: #Predicate { $0.name == name }))) ?? []).first
            let tag = existing ?? {
                let created = MemoryTag(name: dto.name)
                context.insert(created)
                return created
            }()
            dto.apply(to: tag)
        }

        for dto in payload.agentThreads {
            let uuid = dto.uuid
            let existing = ((try? context.fetch(FetchDescriptor<AgentThread>(
                predicate: #Predicate { $0.uuid == uuid }))) ?? []).first
            let thread = existing ?? {
                let created = AgentThread()
                context.insert(created)
                return created
            }()
            dto.apply(to: thread)
        }

        for dto in payload.agentMessages {
            let uuid = dto.uuid
            let existing = ((try? context.fetch(FetchDescriptor<AgentMessage>(
                predicate: #Predicate { $0.uuid == uuid }))) ?? []).first
            let message = existing ?? {
                let created = AgentMessage(threadUUID: dto.threadUUID, role: .user, content: "")
                context.insert(created)
                return created
            }()
            dto.apply(to: message)
        }

        for override in payload.skillOverrides {
            guard let id = AgentSkillID(rawValue: override.id) else { continue }
            AgentSkillStore.save(override.content, for: id)
        }

        applySettings(payload.settings)

        try? context.save()
        WidgetBridge.sync(context: context)
    }

    // MARK: - 内部

    /// files/ 里的条目名和 relativeFilePath 的文件名(App Group 里存的原始文件名,
    /// 建立时就是 "<item uuid>.<ext>")一一对应,直接按名字找、写回同一相对路径即可。
    private static func restoreFile(for dto: BackupMemoryItem, entries: [ZipArchive.Entry]) {
        guard let relativePath = dto.relativeFilePath,
              let containerURL = AppGroup.containerURL else { return }
        let fileName = (relativePath as NSString).lastPathComponent
        guard let entry = entries.first(where: { $0.path == "files/\(fileName)" }) else { return }
        let destURL = containerURL.appending(path: relativePath)
        try? FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? entry.data.write(to: destURL, options: .atomic)
    }

    /// "先清空再导入"策略:删光设备上现有的待办/记忆(连带附件文件与向量分片)/
    /// 标签/AI 对话,后续和 merge 走同一套插入逻辑。
    private static func wipeAllData(context: ModelContext) {
        for item in (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? [] {
            MemoryPipeline.delete(item, context: context)
        }
        for item in (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [] {
            context.delete(item)
        }
        for tag in (try? context.fetch(FetchDescriptor<MemoryTag>())) ?? [] {
            context.delete(tag)
        }
        for thread in (try? context.fetch(FetchDescriptor<AgentThread>())) ?? [] {
            context.delete(thread)
        }
        for message in (try? context.fetch(FetchDescriptor<AgentMessage>())) ?? [] {
            context.delete(message)
        }
        try? context.save()
    }

    private static func currentSettings() -> BackupSettings {
        BackupSettings(
            snoozeMinutes: AppSettings.snoozeMinutes,
            allDayTime: AppSettings.allDayTime,
            digestEnabled: AppSettings.digestEnabled,
            digestTime: AppSettings.digestTime,
            digestTimes: AppSettings.digestTimes.joined(separator: ","),
            digestRepeatType: AppSettings.digestRepeatType,
            digestDays: AppSettings.digestDays.map(String.init).joined(separator: ","),
            hapticsEnabled: AppSettings.hapticsEnabled,
            insightEnabled: AppSettings.insightEnabled,
            agentAutoRecordOnOpen: AppSettings.agentAutoRecordOnOpen,
            agentSilenceTimeoutSeconds: AppSettings.agentSilenceTimeoutSeconds,
            agentPersonaStyle: AppSettings.agentPersonaStyle,
            agentPersonaCustom: UserDefaults.standard.string(
                forKey: AppSettings.agentPersonaCustomKey) ?? "",
            aiProvider: AppSettings.aiProvider,
            aiModel: UserDefaults.standard.string(forKey: AppSettings.aiModelKey) ?? "",
            aiCustomEndpoint: UserDefaults.standard.string(
                forKey: AppSettings.aiCustomEndpointKey) ?? "",
            icloudSyncEnabled: AppSettings.icloudSyncEnabled,
            thinkingLevel: AppSettings.thinkingLevel)
    }

    /// icloudSyncEnabled 若被覆盖,要等下次启动才生效(ModelContainer 只在启动时
    /// 读一次这个开关),这是既有限制,调用方(设置页)负责提示用户。
    private static func applySettings(_ s: BackupSettings) {
        let d = UserDefaults.standard
        d.set(s.snoozeMinutes, forKey: AppSettings.snoozeMinutesKey)
        d.set(s.allDayTime, forKey: AppSettings.allDayTimeKey)
        d.set(s.digestEnabled, forKey: AppSettings.digestEnabledKey)
        d.set(s.digestTime, forKey: AppSettings.digestTimeKey)
        d.set(s.digestTimes, forKey: AppSettings.digestTimesKey)
        d.set(s.digestRepeatType, forKey: AppSettings.digestRepeatTypeKey)
        d.set(s.digestDays, forKey: AppSettings.digestDaysKey)
        d.set(s.hapticsEnabled, forKey: AppSettings.hapticsEnabledKey)
        d.set(s.insightEnabled, forKey: AppSettings.insightEnabledKey)
        d.set(s.agentAutoRecordOnOpen, forKey: AppSettings.agentAutoRecordOnOpenKey)
        d.set(s.agentSilenceTimeoutSeconds, forKey: AppSettings.agentSilenceTimeoutSecondsKey)
        d.set(s.agentPersonaStyle, forKey: AppSettings.agentPersonaStyleKey)
        d.set(s.agentPersonaCustom, forKey: AppSettings.agentPersonaCustomKey)
        d.set(s.aiProvider, forKey: AppSettings.aiProviderKey)
        d.set(s.aiModel, forKey: AppSettings.aiModelKey)
        d.set(s.aiCustomEndpoint, forKey: AppSettings.aiCustomEndpointKey)
        d.set(s.icloudSyncEnabled, forKey: AppSettings.icloudSyncEnabledKey)
        d.set(s.thinkingLevel, forKey: AppSettings.thinkingLevelKey)
    }
}
