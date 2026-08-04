import Foundation

/// 备份文件里的可编解码结构:每个现有模型配一个展平字段的对应物,和
/// `TaskData`/`ParsedTask` 已经是 `TaskItem` 的纯数据对应物同一个思路——字段直接
/// 照抄模型,不做转换。`MemoryChunk`(向量)不在备份范围内:它是从
/// `MemoryItem.sourceText` 派生出来的,导入后跟着"整理失败可重试"的既有路径
/// 自然回填,没必要把体积不小的向量数组塞进备份文件。
/// `BackupSettings` 不含任何 API Key——key 存在钥匙串里,不是 UserDefaults 设置项,
/// 导出成 zip 明文有泄露风险,恢复后用户自己在设置里重新填。

public struct BackupTask: Codable {
    public var uuid: UUID
    public var title: String
    public var remindAt: Date
    public var durationMinutes: Int
    public var allDay: Bool
    public var repeatTypeRaw: String
    public var repeatDays: [Int]
    public var repeatTimes: [String]
    public var statusRaw: String
    public var phaseRaw: String
    public var nextRemindAt: Date
    public var createdAt: Date
    public var doneAt: Date?
    public var ekIdentifier: String?
    public var attachmentKindRaw: String?
    public var attachmentTitle: String?
    public var attachmentSummary: String?
    public var attachmentText: String?
    public var attachmentURLString: String?
    public var attachmentFileName: String?

    public init(
        uuid: UUID, title: String, remindAt: Date, durationMinutes: Int, allDay: Bool,
        repeatTypeRaw: String, repeatDays: [Int], repeatTimes: [String], statusRaw: String,
        phaseRaw: String, nextRemindAt: Date, createdAt: Date, doneAt: Date?,
        ekIdentifier: String?, attachmentKindRaw: String?, attachmentTitle: String?,
        attachmentSummary: String?, attachmentText: String?, attachmentURLString: String?,
        attachmentFileName: String?
    ) {
        self.uuid = uuid
        self.title = title
        self.remindAt = remindAt
        self.durationMinutes = durationMinutes
        self.allDay = allDay
        self.repeatTypeRaw = repeatTypeRaw
        self.repeatDays = repeatDays
        self.repeatTimes = repeatTimes
        self.statusRaw = statusRaw
        self.phaseRaw = phaseRaw
        self.nextRemindAt = nextRemindAt
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.ekIdentifier = ekIdentifier
        self.attachmentKindRaw = attachmentKindRaw
        self.attachmentTitle = attachmentTitle
        self.attachmentSummary = attachmentSummary
        self.attachmentText = attachmentText
        self.attachmentURLString = attachmentURLString
        self.attachmentFileName = attachmentFileName
    }
}

extension TaskItem {
    public var backup: BackupTask {
        BackupTask(
            uuid: uuid, title: title, remindAt: remindAt, durationMinutes: durationMinutes,
            allDay: allDay, repeatTypeRaw: repeatTypeRaw, repeatDays: repeatDays,
            repeatTimes: repeatTimes, statusRaw: statusRaw, phaseRaw: phaseRaw,
            nextRemindAt: nextRemindAt, createdAt: createdAt, doneAt: doneAt,
            ekIdentifier: ekIdentifier, attachmentKindRaw: attachmentKindRaw,
            attachmentTitle: attachmentTitle, attachmentSummary: attachmentSummary,
            attachmentText: attachmentText, attachmentURLString: attachmentURLString,
            attachmentFileName: attachmentFileName)
    }
}

extension BackupTask {
    /// 把这份备份数据整体写进一个 TaskItem(新建的或已存在、按 uuid 匹配到的都行)。
    public func apply(to item: TaskItem) {
        item.uuid = uuid
        item.title = title
        item.remindAt = remindAt
        item.durationMinutes = durationMinutes
        item.allDay = allDay
        item.repeatTypeRaw = repeatTypeRaw
        item.repeatDays = repeatDays
        item.repeatTimes = repeatTimes
        item.statusRaw = statusRaw
        item.phaseRaw = phaseRaw
        item.nextRemindAt = nextRemindAt
        item.createdAt = createdAt
        item.doneAt = doneAt
        item.ekIdentifier = ekIdentifier
        item.attachmentKindRaw = attachmentKindRaw
        item.attachmentTitle = attachmentTitle
        item.attachmentSummary = attachmentSummary
        item.attachmentText = attachmentText
        item.attachmentURLString = attachmentURLString
        item.attachmentFileName = attachmentFileName
    }
}

public struct BackupMemoryItem: Codable {
    public var uuid: UUID
    public var kindRaw: String
    public var title: String
    public var summary: String
    public var tags: [String]
    public var sourceText: String
    public var urlString: String?
    public var originalFileName: String?
    public var relativeFilePath: String?
    public var statusRaw: String
    public var createdAt: Date
    public var assetValue: Double?
    public var contactNickname: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var contactBirthday: Date?
    public var contactPreferences: String?
    public var contactAvatarRelativePath: String?
    /// 非可选数组:老格式备份(这个 key 还不存在)靠这里的默认值兜底解码,
    /// 见 BackupDataTests 的老格式解码回归测试。
    public var attachmentRelativePaths: [String] = []

    public init(
        uuid: UUID, kindRaw: String, title: String, summary: String, tags: [String],
        sourceText: String, urlString: String?, originalFileName: String?,
        relativeFilePath: String?, statusRaw: String, createdAt: Date, assetValue: Double? = nil,
        contactNickname: String? = nil, contactPhone: String? = nil, contactEmail: String? = nil,
        contactBirthday: Date? = nil, contactPreferences: String? = nil,
        contactAvatarRelativePath: String? = nil, attachmentRelativePaths: [String] = []
    ) {
        self.uuid = uuid
        self.kindRaw = kindRaw
        self.title = title
        self.summary = summary
        self.tags = tags
        self.sourceText = sourceText
        self.urlString = urlString
        self.originalFileName = originalFileName
        self.relativeFilePath = relativeFilePath
        self.statusRaw = statusRaw
        self.createdAt = createdAt
        self.assetValue = assetValue
        self.contactNickname = contactNickname
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.contactBirthday = contactBirthday
        self.contactPreferences = contactPreferences
        self.contactAvatarRelativePath = contactAvatarRelativePath
        self.attachmentRelativePaths = attachmentRelativePaths
    }

    /// 手写 init(from:):新增字段用 decodeIfPresent 兜底,老格式备份(这些 key
    /// 还不存在)也能正常解码——自动合成的 init(from:) 对非可选存储属性的
    /// 缺失 key 不会自动落到声明处的默认值,必须手写才能保证向后兼容。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(UUID.self, forKey: .uuid)
        kindRaw = try c.decode(String.self, forKey: .kindRaw)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        tags = try c.decode([String].self, forKey: .tags)
        sourceText = try c.decode(String.self, forKey: .sourceText)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        relativeFilePath = try c.decodeIfPresent(String.self, forKey: .relativeFilePath)
        statusRaw = try c.decode(String.self, forKey: .statusRaw)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        assetValue = try c.decodeIfPresent(Double.self, forKey: .assetValue)
        contactNickname = try c.decodeIfPresent(String.self, forKey: .contactNickname)
        contactPhone = try c.decodeIfPresent(String.self, forKey: .contactPhone)
        contactEmail = try c.decodeIfPresent(String.self, forKey: .contactEmail)
        contactBirthday = try c.decodeIfPresent(Date.self, forKey: .contactBirthday)
        contactPreferences = try c.decodeIfPresent(String.self, forKey: .contactPreferences)
        contactAvatarRelativePath = try c.decodeIfPresent(
            String.self, forKey: .contactAvatarRelativePath)
        attachmentRelativePaths = try c.decodeIfPresent(
            [String].self, forKey: .attachmentRelativePaths) ?? []
    }
}

extension MemoryItem {
    public var backup: BackupMemoryItem {
        BackupMemoryItem(
            uuid: uuid, kindRaw: kindRaw, title: title, summary: summary, tags: tags,
            sourceText: sourceText, urlString: urlString, originalFileName: originalFileName,
            relativeFilePath: relativeFilePath, statusRaw: statusRaw, createdAt: createdAt,
            assetValue: assetValue, contactNickname: contactNickname, contactPhone: contactPhone,
            contactEmail: contactEmail, contactBirthday: contactBirthday,
            contactPreferences: contactPreferences,
            contactAvatarRelativePath: contactAvatarRelativePath,
            attachmentRelativePaths: attachmentRelativePaths)
    }
}

extension BackupMemoryItem {
    public func apply(to item: MemoryItem) {
        item.uuid = uuid
        item.kindRaw = kindRaw
        item.title = title
        item.summary = summary
        item.tags = tags
        item.sourceText = sourceText
        item.urlString = urlString
        item.originalFileName = originalFileName
        item.relativeFilePath = relativeFilePath
        item.statusRaw = statusRaw
        item.createdAt = createdAt
        item.assetValue = assetValue
        item.contactNickname = contactNickname
        item.contactPhone = contactPhone
        item.contactEmail = contactEmail
        item.contactBirthday = contactBirthday
        item.contactPreferences = contactPreferences
        item.contactAvatarRelativePath = contactAvatarRelativePath
        item.attachmentRelativePaths = attachmentRelativePaths
    }
}

public struct BackupContactRelationship: Codable {
    public var uuid: UUID
    public var memoryUUIDA: UUID
    public var memoryUUIDB: UUID
    public var label: String
    public var createdAt: Date

    public init(uuid: UUID, memoryUUIDA: UUID, memoryUUIDB: UUID, label: String, createdAt: Date) {
        self.uuid = uuid
        self.memoryUUIDA = memoryUUIDA
        self.memoryUUIDB = memoryUUIDB
        self.label = label
        self.createdAt = createdAt
    }
}

extension ContactRelationship {
    public var backup: BackupContactRelationship {
        BackupContactRelationship(
            uuid: uuid, memoryUUIDA: memoryUUIDA, memoryUUIDB: memoryUUIDB, label: label,
            createdAt: createdAt)
    }
}

extension BackupContactRelationship {
    public func apply(to relationship: ContactRelationship) {
        relationship.uuid = uuid
        relationship.memoryUUIDA = memoryUUIDA
        relationship.memoryUUIDB = memoryUUIDB
        relationship.label = label
        relationship.createdAt = createdAt
    }
}

public struct BackupMemoryTag: Codable {
    public var name: String
    public var createdAt: Date

    public init(name: String, createdAt: Date) {
        self.name = name
        self.createdAt = createdAt
    }
}

extension MemoryTag {
    public var backup: BackupMemoryTag { BackupMemoryTag(name: name, createdAt: createdAt) }
}

extension BackupMemoryTag {
    public func apply(to tag: MemoryTag) {
        tag.name = name
        tag.createdAt = createdAt
    }
}

public struct BackupAgentThread: Codable {
    public var uuid: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(uuid: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.uuid = uuid
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension AgentThread {
    public var backup: BackupAgentThread {
        BackupAgentThread(uuid: uuid, title: title, createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension BackupAgentThread {
    public func apply(to thread: AgentThread) {
        thread.uuid = uuid
        thread.title = title
        thread.createdAt = createdAt
        thread.updatedAt = updatedAt
    }
}

public struct BackupAgentMessage: Codable {
    public var uuid: UUID
    public var threadUUID: UUID
    public var roleRaw: String
    public var kindRaw: String
    public var content: String
    public var relatedTitles: [String]
    public var attachmentMemoryUUIDs: [UUID]
    public var createdAt: Date

    public init(
        uuid: UUID, threadUUID: UUID, roleRaw: String, kindRaw: String, content: String,
        relatedTitles: [String], attachmentMemoryUUIDs: [UUID],
        createdAt: Date
    ) {
        self.uuid = uuid
        self.threadUUID = threadUUID
        self.roleRaw = roleRaw
        self.kindRaw = kindRaw
        self.content = content
        self.relatedTitles = relatedTitles
        self.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        self.createdAt = createdAt
    }
}

extension AgentMessage {
    public var backup: BackupAgentMessage {
        BackupAgentMessage(
            uuid: uuid, threadUUID: threadUUID, roleRaw: roleRaw, kindRaw: kindRaw,
            content: content, relatedTitles: relatedTitles,
            attachmentMemoryUUIDs: attachmentMemoryUUIDs, createdAt: createdAt)
    }
}

extension BackupAgentMessage {
    public func apply(to message: AgentMessage) {
        message.uuid = uuid
        message.threadUUID = threadUUID
        message.roleRaw = roleRaw
        message.kindRaw = kindRaw
        message.content = content
        message.relatedTitles = relatedTitles
        message.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        message.createdAt = createdAt
    }
}

/// 只收用户实际编辑过的 skill(`AgentSkillStore.isCustomized(_:) == true`),
/// 默认内容不用导出——恢复时按内置默认值就能重新算出来。
public struct BackupSkillOverride: Codable {
    public var id: String
    public var content: String

    public init(id: String, content: String) {
        self.id = id
        self.content = content
    }
}

/// `AppSettings.swift` 里 17 个 key 原样对应,类型与 UserDefaults 里实际存的值一致
/// (`@AppStorage` 读写的就是这些原始类型);不含任何 API Key。
public struct BackupSettings: Codable {
    public var snoozeMinutes: Int
    public var allDayTime: String
    public var digestEnabled: Bool
    public var digestTime: String
    public var digestTimes: String
    public var digestRepeatType: String
    public var digestDays: String
    public var hapticsEnabled: Bool
    public var insightEnabled: Bool
    public var agentSilenceTimeoutSeconds: Int
    public var agentPersonaStyle: String
    public var agentPersonaCustom: String
    public var aiProvider: String
    public var aiModel: String
    public var aiCustomEndpoint: String
    public var icloudSyncEnabled: Bool
    public var thinkingLevel: String

    public init(
        snoozeMinutes: Int, allDayTime: String, digestEnabled: Bool, digestTime: String,
        digestTimes: String, digestRepeatType: String, digestDays: String, hapticsEnabled: Bool,
        insightEnabled: Bool, agentSilenceTimeoutSeconds: Int,
        agentPersonaStyle: String, agentPersonaCustom: String, aiProvider: String,
        aiModel: String, aiCustomEndpoint: String, icloudSyncEnabled: Bool,
        thinkingLevel: String = "medium"
    ) {
        self.snoozeMinutes = snoozeMinutes
        self.allDayTime = allDayTime
        self.digestEnabled = digestEnabled
        self.digestTime = digestTime
        self.digestTimes = digestTimes
        self.digestRepeatType = digestRepeatType
        self.digestDays = digestDays
        self.hapticsEnabled = hapticsEnabled
        self.insightEnabled = insightEnabled
        self.agentSilenceTimeoutSeconds = agentSilenceTimeoutSeconds
        self.agentPersonaStyle = agentPersonaStyle
        self.agentPersonaCustom = agentPersonaCustom
        self.aiProvider = aiProvider
        self.aiModel = aiModel
        self.aiCustomEndpoint = aiCustomEndpoint
        self.icloudSyncEnabled = icloudSyncEnabled
        self.thinkingLevel = thinkingLevel
    }
}

/// zip 里 `manifest.json` 的内容:格式版本 + 导出时间 + 各类目数量,供导入前的
/// 预览确认页读取,不需要先解出整份 `data.json` 就能展示"包含 N 条待办…"。
public struct BackupManifest: Codable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var taskCount: Int
    public var memoryCount: Int
    public var memoryTagCount: Int
    public var agentThreadCount: Int
    public var agentMessageCount: Int
    public var skillOverrideCount: Int
    public var contactRelationshipCount: Int = 0

    public init(
        formatVersion: Int, exportedAt: Date, appVersion: String, taskCount: Int,
        memoryCount: Int, memoryTagCount: Int, agentThreadCount: Int, agentMessageCount: Int,
        skillOverrideCount: Int, contactRelationshipCount: Int = 0
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.taskCount = taskCount
        self.memoryCount = memoryCount
        self.memoryTagCount = memoryTagCount
        self.agentThreadCount = agentThreadCount
        self.agentMessageCount = agentMessageCount
        self.skillOverrideCount = skillOverrideCount
        self.contactRelationshipCount = contactRelationshipCount
    }

    public static let currentFormatVersion = 1
}

/// zip 里 `data.json` 的内容:除 manifest 外的全部数据(不含 `files/` 目录里的
/// 二进制附件,那些按 uuid 文件名单独存)。
public struct BackupPayload: Codable {
    public var tasks: [BackupTask]
    public var memoryItems: [BackupMemoryItem]
    public var memoryTags: [BackupMemoryTag]
    public var agentThreads: [BackupAgentThread]
    public var agentMessages: [BackupAgentMessage]
    public var skillOverrides: [BackupSkillOverride]
    public var settings: BackupSettings
    /// 非可选数组:老格式备份没有这个 key,靠默认值兜底解码(同
    /// attachmentRelativePaths,见 BackupDataTests 的老格式解码回归测试)。
    public var contactRelationships: [BackupContactRelationship] = []

    public init(
        tasks: [BackupTask], memoryItems: [BackupMemoryItem], memoryTags: [BackupMemoryTag],
        agentThreads: [BackupAgentThread], agentMessages: [BackupAgentMessage],
        skillOverrides: [BackupSkillOverride], settings: BackupSettings,
        contactRelationships: [BackupContactRelationship] = []
    ) {
        self.tasks = tasks
        self.memoryItems = memoryItems
        self.memoryTags = memoryTags
        self.agentThreads = agentThreads
        self.agentMessages = agentMessages
        self.skillOverrides = skillOverrides
        self.settings = settings
        self.contactRelationships = contactRelationships
    }

    /// 手写 init(from:):contactRelationships 是新增字段,老格式备份没有这个
    /// key 时用空数组兜底,理由同 BackupMemoryItem 的手写 init(from:)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([BackupTask].self, forKey: .tasks)
        memoryItems = try c.decode([BackupMemoryItem].self, forKey: .memoryItems)
        memoryTags = try c.decode([BackupMemoryTag].self, forKey: .memoryTags)
        agentThreads = try c.decode([BackupAgentThread].self, forKey: .agentThreads)
        agentMessages = try c.decode([BackupAgentMessage].self, forKey: .agentMessages)
        skillOverrides = try c.decode([BackupSkillOverride].self, forKey: .skillOverrides)
        settings = try c.decode(BackupSettings.self, forKey: .settings)
        contactRelationships = try c.decodeIfPresent(
            [BackupContactRelationship].self, forKey: .contactRelationships) ?? []
    }
}
