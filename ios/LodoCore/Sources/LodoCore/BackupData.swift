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
    public var project: String?
    public var attachmentKindRaw: String?
    public var attachmentTitle: String?
    public var attachmentSummary: String?
    public var attachmentText: String?
    public var attachmentURLString: String?
    public var attachmentFileName: String?
    public var ignoreStreak: Int

    public init(
        uuid: UUID, title: String, remindAt: Date, durationMinutes: Int, allDay: Bool,
        repeatTypeRaw: String, repeatDays: [Int], repeatTimes: [String], statusRaw: String,
        phaseRaw: String, nextRemindAt: Date, createdAt: Date, doneAt: Date?,
        ekIdentifier: String?, project: String? = nil, attachmentKindRaw: String?,
        attachmentTitle: String?,
        attachmentSummary: String?, attachmentText: String?, attachmentURLString: String?,
        attachmentFileName: String?, ignoreStreak: Int = 0
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
        self.project = project
        self.attachmentKindRaw = attachmentKindRaw
        self.attachmentTitle = attachmentTitle
        self.attachmentSummary = attachmentSummary
        self.attachmentText = attachmentText
        self.attachmentURLString = attachmentURLString
        self.attachmentFileName = attachmentFileName
        self.ignoreStreak = ignoreStreak
    }

    /// 手写 init(from:):ignoreStreak 是新增的非可选字段,老格式备份没有这个
    /// key 时用 0 兜底(合成 Codable 只对可选属性的缺失 key 安全,理由同
    /// BackupSettings/BackupPayload 的手写 init(from:))。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(UUID.self, forKey: .uuid)
        title = try c.decode(String.self, forKey: .title)
        remindAt = try c.decode(Date.self, forKey: .remindAt)
        durationMinutes = try c.decode(Int.self, forKey: .durationMinutes)
        allDay = try c.decode(Bool.self, forKey: .allDay)
        repeatTypeRaw = try c.decode(String.self, forKey: .repeatTypeRaw)
        repeatDays = try c.decode([Int].self, forKey: .repeatDays)
        repeatTimes = try c.decode([String].self, forKey: .repeatTimes)
        statusRaw = try c.decode(String.self, forKey: .statusRaw)
        phaseRaw = try c.decode(String.self, forKey: .phaseRaw)
        nextRemindAt = try c.decode(Date.self, forKey: .nextRemindAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        ekIdentifier = try c.decodeIfPresent(String.self, forKey: .ekIdentifier)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        attachmentKindRaw = try c.decodeIfPresent(String.self, forKey: .attachmentKindRaw)
        attachmentTitle = try c.decodeIfPresent(String.self, forKey: .attachmentTitle)
        attachmentSummary = try c.decodeIfPresent(String.self, forKey: .attachmentSummary)
        attachmentText = try c.decodeIfPresent(String.self, forKey: .attachmentText)
        attachmentURLString = try c.decodeIfPresent(String.self, forKey: .attachmentURLString)
        attachmentFileName = try c.decodeIfPresent(String.self, forKey: .attachmentFileName)
        ignoreStreak = try c.decodeIfPresent(Int.self, forKey: .ignoreStreak) ?? 0
    }
}

extension TaskItem {
    public var backup: BackupTask {
        BackupTask(
            uuid: uuid, title: title, remindAt: remindAt, durationMinutes: durationMinutes,
            allDay: allDay, repeatTypeRaw: repeatTypeRaw, repeatDays: repeatDays,
            repeatTimes: repeatTimes, statusRaw: statusRaw, phaseRaw: phaseRaw,
            nextRemindAt: nextRemindAt, createdAt: createdAt, doneAt: doneAt,
            ekIdentifier: ekIdentifier, project: project, attachmentKindRaw: attachmentKindRaw,
            attachmentTitle: attachmentTitle, attachmentSummary: attachmentSummary,
            attachmentText: attachmentText, attachmentURLString: attachmentURLString,
            attachmentFileName: attachmentFileName, ignoreStreak: ignoreStreak)
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
        item.project = project
        item.attachmentKindRaw = attachmentKindRaw
        item.attachmentTitle = attachmentTitle
        item.attachmentSummary = attachmentSummary
        item.attachmentText = attachmentText
        item.attachmentURLString = attachmentURLString
        item.attachmentFileName = attachmentFileName
        item.ignoreStreak = ignoreStreak
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
    public var assetCurrency: String?
    public var assetLiability: Double?
    public var assetInterestRate: Double?
    public var contactNickname: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var contactBirthday: Date?
    public var contactPreferences: String?
    public var contactAvatarRelativePath: String?
    /// 非可选数组:老格式备份(这个 key 还不存在)靠这里的默认值兜底解码,
    /// 见 BackupDataTests 的老格式解码回归测试。
    public var attachmentRelativePaths: [String] = []
    // 旅行字段:全是可选,老格式备份缺这些 key 时下面手写的 init(from:) 用 nil 兜底。
    public var travelTripUUID: UUID?
    public var travelKindRaw: String?
    public var travelStart: Date?
    public var travelEnd: Date?
    public var travelPrice: Double?
    public var travelCurrency: String?
    public var travelPlaceName: String?
    public var travelLatitude: Double?
    public var travelLongitude: Double?
    public var travelOriginName: String?
    public var travelOriginLatitude: Double?
    public var travelOriginLongitude: Double?
    public var travelCode: String?
    public var travelFlightData: Data?
    // 菜单字段:同样全是可选,老格式备份缺这些 key 时下面的 init(from:) 用 nil 兜底。
    public var menuSourceLanguage: String?
    public var menuTargetLanguage: String?
    public var menuCurrency: String?

    public init(
        uuid: UUID, kindRaw: String, title: String, summary: String, tags: [String],
        sourceText: String, urlString: String?, originalFileName: String?,
        relativeFilePath: String?, statusRaw: String, createdAt: Date, assetValue: Double? = nil,
        assetCurrency: String? = nil, assetLiability: Double? = nil,
        assetInterestRate: Double? = nil,
        contactNickname: String? = nil, contactPhone: String? = nil, contactEmail: String? = nil,
        contactBirthday: Date? = nil, contactPreferences: String? = nil,
        contactAvatarRelativePath: String? = nil, attachmentRelativePaths: [String] = [],
        travelTripUUID: UUID? = nil,
        travelKindRaw: String? = nil,
        travelStart: Date? = nil,
        travelEnd: Date? = nil,
        travelPrice: Double? = nil,
        travelCurrency: String? = nil,
        travelPlaceName: String? = nil,
        travelLatitude: Double? = nil,
        travelLongitude: Double? = nil,
        travelOriginName: String? = nil,
        travelOriginLatitude: Double? = nil,
        travelOriginLongitude: Double? = nil,
        travelCode: String? = nil,
        travelFlightData: Data? = nil,
        menuSourceLanguage: String? = nil,
        menuTargetLanguage: String? = nil,
        menuCurrency: String? = nil
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
        self.assetCurrency = assetCurrency
        self.assetLiability = assetLiability
        self.assetInterestRate = assetInterestRate
        self.contactNickname = contactNickname
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.contactBirthday = contactBirthday
        self.contactPreferences = contactPreferences
        self.contactAvatarRelativePath = contactAvatarRelativePath
        self.attachmentRelativePaths = attachmentRelativePaths
        self.travelTripUUID = travelTripUUID
        self.travelKindRaw = travelKindRaw
        self.travelStart = travelStart
        self.travelEnd = travelEnd
        self.travelPrice = travelPrice
        self.travelCurrency = travelCurrency
        self.travelPlaceName = travelPlaceName
        self.travelLatitude = travelLatitude
        self.travelLongitude = travelLongitude
        self.travelOriginName = travelOriginName
        self.travelOriginLatitude = travelOriginLatitude
        self.travelOriginLongitude = travelOriginLongitude
        self.travelCode = travelCode
        self.travelFlightData = travelFlightData
        self.menuSourceLanguage = menuSourceLanguage
        self.menuTargetLanguage = menuTargetLanguage
        self.menuCurrency = menuCurrency
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
        assetCurrency = try c.decodeIfPresent(String.self, forKey: .assetCurrency)
        assetLiability = try c.decodeIfPresent(Double.self, forKey: .assetLiability)
        assetInterestRate = try c.decodeIfPresent(Double.self, forKey: .assetInterestRate)
        contactNickname = try c.decodeIfPresent(String.self, forKey: .contactNickname)
        contactPhone = try c.decodeIfPresent(String.self, forKey: .contactPhone)
        contactEmail = try c.decodeIfPresent(String.self, forKey: .contactEmail)
        contactBirthday = try c.decodeIfPresent(Date.self, forKey: .contactBirthday)
        contactPreferences = try c.decodeIfPresent(String.self, forKey: .contactPreferences)
        contactAvatarRelativePath = try c.decodeIfPresent(
            String.self, forKey: .contactAvatarRelativePath)
        attachmentRelativePaths = try c.decodeIfPresent(
            [String].self, forKey: .attachmentRelativePaths) ?? []
        travelTripUUID = try c.decodeIfPresent(UUID.self, forKey: .travelTripUUID)
        travelKindRaw = try c.decodeIfPresent(String.self, forKey: .travelKindRaw)
        travelStart = try c.decodeIfPresent(Date.self, forKey: .travelStart)
        travelEnd = try c.decodeIfPresent(Date.self, forKey: .travelEnd)
        travelPrice = try c.decodeIfPresent(Double.self, forKey: .travelPrice)
        travelCurrency = try c.decodeIfPresent(String.self, forKey: .travelCurrency)
        travelPlaceName = try c.decodeIfPresent(String.self, forKey: .travelPlaceName)
        travelLatitude = try c.decodeIfPresent(Double.self, forKey: .travelLatitude)
        travelLongitude = try c.decodeIfPresent(Double.self, forKey: .travelLongitude)
        travelOriginName = try c.decodeIfPresent(String.self, forKey: .travelOriginName)
        travelOriginLatitude = try c.decodeIfPresent(Double.self, forKey: .travelOriginLatitude)
        travelOriginLongitude = try c.decodeIfPresent(Double.self, forKey: .travelOriginLongitude)
        travelCode = try c.decodeIfPresent(String.self, forKey: .travelCode)
        travelFlightData = try c.decodeIfPresent(Data.self, forKey: .travelFlightData)
        menuSourceLanguage = try c.decodeIfPresent(String.self, forKey: .menuSourceLanguage)
        menuTargetLanguage = try c.decodeIfPresent(String.self, forKey: .menuTargetLanguage)
        menuCurrency = try c.decodeIfPresent(String.self, forKey: .menuCurrency)
    }
}

extension MemoryItem {
    public var backup: BackupMemoryItem {
        BackupMemoryItem(
            uuid: uuid, kindRaw: kindRaw, title: title, summary: summary, tags: tags,
            sourceText: sourceText, urlString: urlString, originalFileName: originalFileName,
            relativeFilePath: relativeFilePath, statusRaw: statusRaw, createdAt: createdAt,
            assetValue: assetValue, assetCurrency: assetCurrency,
            assetLiability: assetLiability, assetInterestRate: assetInterestRate,
            contactNickname: contactNickname, contactPhone: contactPhone,
            contactEmail: contactEmail, contactBirthday: contactBirthday,
            contactPreferences: contactPreferences,
            contactAvatarRelativePath: contactAvatarRelativePath,
            attachmentRelativePaths: attachmentRelativePaths,
            travelTripUUID: travelTripUUID,
            travelKindRaw: travelKindRaw,
            travelStart: travelStart,
            travelEnd: travelEnd,
            travelPrice: travelPrice,
            travelCurrency: travelCurrency,
            travelPlaceName: travelPlaceName,
            travelLatitude: travelLatitude,
            travelLongitude: travelLongitude,
            travelOriginName: travelOriginName,
            travelOriginLatitude: travelOriginLatitude,
            travelOriginLongitude: travelOriginLongitude,
            travelCode: travelCode,
            travelFlightData: travelFlightData,
            menuSourceLanguage: menuSourceLanguage,
            menuTargetLanguage: menuTargetLanguage,
            menuCurrency: menuCurrency)
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
        item.assetCurrency = assetCurrency
        item.assetLiability = assetLiability
        item.assetInterestRate = assetInterestRate
        item.contactNickname = contactNickname
        item.contactPhone = contactPhone
        item.contactEmail = contactEmail
        item.contactBirthday = contactBirthday
        item.contactPreferences = contactPreferences
        item.contactAvatarRelativePath = contactAvatarRelativePath
        item.attachmentRelativePaths = attachmentRelativePaths
        item.travelTripUUID = travelTripUUID
        item.travelKindRaw = travelKindRaw
        item.travelStart = travelStart
        item.travelEnd = travelEnd
        item.travelPrice = travelPrice
        item.travelCurrency = travelCurrency
        item.travelPlaceName = travelPlaceName
        item.travelLatitude = travelLatitude
        item.travelLongitude = travelLongitude
        item.travelOriginName = travelOriginName
        item.travelOriginLatitude = travelOriginLatitude
        item.travelOriginLongitude = travelOriginLongitude
        item.travelCode = travelCode
        item.travelFlightData = travelFlightData
        item.menuSourceLanguage = menuSourceLanguage
        item.menuTargetLanguage = menuTargetLanguage
        item.menuCurrency = menuCurrency
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

public struct BackupTravelTrip: Codable {
    public var uuid: UUID
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var notes: String
    public var city: String
    public var country: String
    public var createdAt: Date

    public init(uuid: UUID, title: String, startDate: Date, endDate: Date,
                notes: String, city: String = "", country: String = "", createdAt: Date) {
        self.uuid = uuid
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.city = city
        self.country = country
        self.createdAt = createdAt
    }

    /// 手写 init(from:):city/country 是后加的字段,老备份没有这两个 key 时按空串处理。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(UUID.self, forKey: .uuid)
        title = try c.decode(String.self, forKey: .title)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        notes = try c.decode(String.self, forKey: .notes)
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

extension TravelTrip {
    public var backup: BackupTravelTrip {
        BackupTravelTrip(uuid: uuid, title: title, startDate: startDate, endDate: endDate,
                         notes: notes, city: city, country: country, createdAt: createdAt)
    }
}

extension BackupTravelTrip {
    public func apply(to trip: TravelTrip) {
        trip.uuid = uuid
        trip.title = title
        trip.startDate = startDate
        trip.endDate = endDate
        trip.notes = notes
        trip.city = city
        trip.country = country
        trip.createdAt = createdAt
    }
}

/// 菜品。菜单本身是 MemoryItem(已经在 memoryItems 里了),菜品是独立的轻量模型,
/// 所以这里要单独备份一份——只备份菜单不备份菜品,恢复出来就是一条点不开东西的
/// 空菜单(同 travelTrips 那条注释的道理,只是方向反过来)。
public struct BackupMenuDish: Codable {
    public var uuid: UUID
    public var menuUUID: UUID
    public var originalName: String
    public var translatedName: String
    public var intro: String
    public var category: String
    public var price: Double?
    public var sortIndex: Int
    public var selected: Bool
    public var createdAt: Date

    public init(uuid: UUID, menuUUID: UUID, originalName: String, translatedName: String,
                intro: String, category: String, price: Double?, sortIndex: Int,
                selected: Bool, createdAt: Date) {
        self.uuid = uuid
        self.menuUUID = menuUUID
        self.originalName = originalName
        self.translatedName = translatedName
        self.intro = intro
        self.category = category
        self.price = price
        self.sortIndex = sortIndex
        self.selected = selected
        self.createdAt = createdAt
    }
}

extension MenuDish {
    public var backup: BackupMenuDish {
        BackupMenuDish(uuid: uuid, menuUUID: menuUUID, originalName: originalName,
                       translatedName: translatedName, intro: intro, category: category,
                       price: price, sortIndex: sortIndex, selected: selected,
                       createdAt: createdAt)
    }
}

extension BackupMenuDish {
    public func apply(to dish: MenuDish) {
        dish.uuid = uuid
        dish.menuUUID = menuUUID
        dish.originalName = originalName
        dish.translatedName = translatedName
        dish.intro = intro
        dish.category = category
        dish.price = price
        dish.sortIndex = sortIndex
        dish.selected = selected
        dish.createdAt = createdAt
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

public struct BackupAgentMessage: Codable {
    public var uuid: UUID
    /// 已退役的 key(多对话改成单一持续对话时 `AgentMessage.threadUUID` 一起删了)。
    /// 属性留着只为**向下**兼容:老版本 app 里这个 key 是必需的,新备份不写它会让
    /// 那边整条 decode 失败——比少恢复一段对话糟得多。恒为全零 uuid,自己不读。
    public var threadUUID = BackupAgentMessage.retiredThreadUUID
    /// 退役字段的占位值。固定全零而不是随机 uuid:同一份数据反复导出时
    /// 内容要稳定(便于 diff),而且老版本 app 拿到它只会落进一个不存在的
    /// thread,看不见也不报错。
    public static let retiredThreadUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public var roleRaw: String
    public var kindRaw: String
    public var content: String
    public var relatedTitles: [String]
    public var attachmentMemoryUUIDs: [UUID]
    public var createdAt: Date

    public init(
        uuid: UUID, roleRaw: String, kindRaw: String, content: String,
        relatedTitles: [String], attachmentMemoryUUIDs: [UUID],
        createdAt: Date
    ) {
        self.uuid = uuid
        self.roleRaw = roleRaw
        self.kindRaw = kindRaw
        self.content = content
        self.relatedTitles = relatedTitles
        self.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        self.createdAt = createdAt
    }
}

extension BackupAgentMessage {
    /// 手写 init(from:):`threadUUID` 已退役,自己不再读它,但为了向下兼容仍要
    /// **写**出去(老版本 app 那边它是必需 key)。读的时候用 decodeIfPresent,
    /// 这样"将来某个版本真把这个 key 去掉了"也照样解得开——不然这份兼容就
    /// 反过来变成了新格式自己的枷锁。理由同 `BackupManifest` 的手写 init(from:)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(UUID.self, forKey: .uuid)
        threadUUID = try c.decodeIfPresent(UUID.self, forKey: .threadUUID) ?? Self.retiredThreadUUID
        roleRaw = try c.decode(String.self, forKey: .roleRaw)
        kindRaw = try c.decode(String.self, forKey: .kindRaw)
        content = try c.decode(String.self, forKey: .content)
        relatedTitles = try c.decode([String].self, forKey: .relatedTitles)
        attachmentMemoryUUIDs = try c.decode([UUID].self, forKey: .attachmentMemoryUUIDs)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

extension AgentMessage {
    public var backup: BackupAgentMessage {
        BackupAgentMessage(
            uuid: uuid, roleRaw: roleRaw, kindRaw: kindRaw,
            content: content, relatedTitles: relatedTitles,
            attachmentMemoryUUIDs: attachmentMemoryUUIDs, createdAt: createdAt)
    }
}

extension BackupAgentMessage {
    public func apply(to message: AgentMessage) {
        message.uuid = uuid
        message.roleRaw = roleRaw
        message.kindRaw = kindRaw
        message.content = content
        message.relatedTitles = relatedTitles
        message.attachmentMemoryUUIDs = attachmentMemoryUUIDs
        message.createdAt = createdAt
        // 显式写 1:恢复出来的消息若留在默认的 0,下次启动会被
        // `AgentHistoryMigration` 当成待清理的老分段对话删光。
        message.formatVersion = 1
    }
}

/// 用户导入/新建的外部 skill:`content` 是完整的分享格式文本(含 frontmatter),
/// 恢复时按 slug 写回,启用状态一并带上。
public struct BackupCustomSkill: Codable {
    public var slug: String
    public var content: String
    public var enabled: Bool

    public init(slug: String, content: String, enabled: Bool) {
        self.slug = slug
        self.content = content
        self.enabled = enabled
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
    /// 老格式备份没有这几个 key,靠默认值兜底解码(同 contactRelationshipCount)。
    public var sttEngine: String = "qwenASR"
    public var useBuiltInSTTKey: Bool = true
    public var quietHoursEnabled: Bool = true
    public var quietHoursStart: String = "22:00"
    public var quietHoursEnd: String = "08:00"

    public init(
        snoozeMinutes: Int, allDayTime: String, digestEnabled: Bool, digestTime: String,
        digestTimes: String, digestRepeatType: String, digestDays: String, hapticsEnabled: Bool,
        insightEnabled: Bool, agentSilenceTimeoutSeconds: Int,
        agentPersonaStyle: String, agentPersonaCustom: String, aiProvider: String,
        aiModel: String, aiCustomEndpoint: String, icloudSyncEnabled: Bool,
        thinkingLevel: String = "medium", sttEngine: String = "qwenASR",
        useBuiltInSTTKey: Bool = true, quietHoursEnabled: Bool = true,
        quietHoursStart: String = "22:00", quietHoursEnd: String = "08:00"
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
        self.sttEngine = sttEngine
        self.useBuiltInSTTKey = useBuiltInSTTKey
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    /// 手写 init(from:):sttEngine/useBuiltInSTTKey 是新增字段,老格式备份没有
    /// 这两个 key 时用默认值兜底(属性声明处的默认值只影响构造,不影响解码——
    /// 光靠那个不够,这里必须显式 decodeIfPresent,理由同 BackupPayload 的
    /// contactRelationships 手写 init(from:))。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snoozeMinutes = try c.decode(Int.self, forKey: .snoozeMinutes)
        allDayTime = try c.decode(String.self, forKey: .allDayTime)
        digestEnabled = try c.decode(Bool.self, forKey: .digestEnabled)
        digestTime = try c.decode(String.self, forKey: .digestTime)
        digestTimes = try c.decode(String.self, forKey: .digestTimes)
        digestRepeatType = try c.decode(String.self, forKey: .digestRepeatType)
        digestDays = try c.decode(String.self, forKey: .digestDays)
        hapticsEnabled = try c.decode(Bool.self, forKey: .hapticsEnabled)
        insightEnabled = try c.decode(Bool.self, forKey: .insightEnabled)
        agentSilenceTimeoutSeconds = try c.decode(Int.self, forKey: .agentSilenceTimeoutSeconds)
        agentPersonaStyle = try c.decode(String.self, forKey: .agentPersonaStyle)
        agentPersonaCustom = try c.decode(String.self, forKey: .agentPersonaCustom)
        aiProvider = try c.decode(String.self, forKey: .aiProvider)
        aiModel = try c.decode(String.self, forKey: .aiModel)
        aiCustomEndpoint = try c.decode(String.self, forKey: .aiCustomEndpoint)
        icloudSyncEnabled = try c.decode(Bool.self, forKey: .icloudSyncEnabled)
        thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel) ?? "medium"
        sttEngine = try c.decodeIfPresent(String.self, forKey: .sttEngine) ?? "qwenASR"
        useBuiltInSTTKey = try c.decodeIfPresent(Bool.self, forKey: .useBuiltInSTTKey) ?? true
        quietHoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? true
        quietHoursStart = try c.decodeIfPresent(String.self, forKey: .quietHoursStart) ?? "22:00"
        quietHoursEnd = try c.decodeIfPresent(String.self, forKey: .quietHoursEnd) ?? "08:00"
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
    /// 已退役,恒为 0(对话不再分段)。留着字段同样是为了向下兼容:老版本 app
    /// 里这个 key 是必需的。老备份里的真实值仍解得进来,只是没人再读。
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

    /// 手写 init(from:):`contactRelationshipCount` 是后加的字段、
    /// `agentThreadCount` 是已退役的字段,老备份/将来的新备份都可能缺其中一个。
    /// **合成的 Codable 不会用属性的默认值兜底**(缺 key 直接抛 keyNotFound),
    /// 而 manifest 是导入的第一步——它一抛错,用户连确认页都走不到,整份备份
    /// 一条都恢复不了。理由同 `BackupPayload` 的手写 init(from:)。
    /// 以后再加计数字段,记得也加在这里、并且用 decodeIfPresent。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        taskCount = try c.decode(Int.self, forKey: .taskCount)
        memoryCount = try c.decode(Int.self, forKey: .memoryCount)
        memoryTagCount = try c.decode(Int.self, forKey: .memoryTagCount)
        agentThreadCount = try c.decodeIfPresent(Int.self, forKey: .agentThreadCount) ?? 0
        agentMessageCount = try c.decode(Int.self, forKey: .agentMessageCount)
        skillOverrideCount = try c.decode(Int.self, forKey: .skillOverrideCount)
        contactRelationshipCount =
            try c.decodeIfPresent(Int.self, forKey: .contactRelationshipCount) ?? 0
    }

    public static let currentFormatVersion = 1
}

/// zip 里 `data.json` 的内容:除 manifest 外的全部数据(不含 `files/` 目录里的
/// 二进制附件,那些按 uuid 文件名单独存)。
public struct BackupPayload: Codable {
    public var tasks: [BackupTask]
    public var memoryItems: [BackupMemoryItem]
    public var memoryTags: [BackupMemoryTag]
    /// 已退役的 key,理由同 `BackupAgentMessage.threadUUID`;恒为空数组。
    /// 元素类型换成 Int 只是为了不用再留着 `BackupAgentThread` 那个结构体——
    /// 空数组的编码形态与元素类型无关,老版本 app 照样解得出 `[]`。
    public var agentThreads: [Int] = []
    public var agentMessages: [BackupAgentMessage]
    public var skillOverrides: [BackupSkillOverride]
    public var settings: BackupSettings
    /// 非可选数组:老格式备份没有这个 key,靠默认值兜底解码(同
    /// attachmentRelativePaths,见 BackupDataTests 的老格式解码回归测试)。
    public var contactRelationships: [BackupContactRelationship] = []
    /// 旅行。行程项本身是 MemoryItem,已经在 memoryItems 里了;这里只补"旅行本身",
    /// 否则恢复出来的行程项会指向一个不存在的 trip,静默退化成普通记忆条目。
    public var travelTrips: [BackupTravelTrip] = []
    /// 菜品。菜单那条记忆条目已经在 memoryItems 里,这里补它下面的菜。
    public var menuDishes: [BackupMenuDish] = []
    /// 外部 skill 与内置 skill 的启用状态。都是新增字段,老备份缺 key 时兜底为空。
    /// skillEnabled 只记被停用的内置 skill(默认就是开,不用存)。
    public var customSkills: [BackupCustomSkill] = []
    public var disabledSkills: [String] = []

    public init(
        tasks: [BackupTask], memoryItems: [BackupMemoryItem], memoryTags: [BackupMemoryTag],
        agentMessages: [BackupAgentMessage],
        skillOverrides: [BackupSkillOverride], settings: BackupSettings,
        contactRelationships: [BackupContactRelationship] = [],
        travelTrips: [BackupTravelTrip] = [],
        menuDishes: [BackupMenuDish] = [],
        customSkills: [BackupCustomSkill] = [],
        disabledSkills: [String] = []
    ) {
        self.tasks = tasks
        self.memoryItems = memoryItems
        self.memoryTags = memoryTags
        self.agentMessages = agentMessages
        self.skillOverrides = skillOverrides
        self.settings = settings
        self.contactRelationships = contactRelationships
        self.travelTrips = travelTrips
        self.menuDishes = menuDishes
        self.customSkills = customSkills
        self.disabledSkills = disabledSkills
    }

    /// 手写 init(from:):contactRelationships/travelTrips/menuDishes 是新增字段,
    /// 老格式备份没有这些 key 时用空数组兜底,理由同 BackupMemoryItem 的手写 init(from:)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([BackupTask].self, forKey: .tasks)
        memoryItems = try c.decode([BackupMemoryItem].self, forKey: .memoryItems)
        memoryTags = try c.decode([BackupMemoryTag].self, forKey: .memoryTags)
        // agentThreads 已退役,不再读(老备份里那段数据没有对应的模型可落)。
        agentMessages = try c.decode([BackupAgentMessage].self, forKey: .agentMessages)
        skillOverrides = try c.decode([BackupSkillOverride].self, forKey: .skillOverrides)
        settings = try c.decode(BackupSettings.self, forKey: .settings)
        contactRelationships = try c.decodeIfPresent(
            [BackupContactRelationship].self, forKey: .contactRelationships) ?? []
        travelTrips = try c.decodeIfPresent(
            [BackupTravelTrip].self, forKey: .travelTrips) ?? []
        menuDishes = try c.decodeIfPresent(
            [BackupMenuDish].self, forKey: .menuDishes) ?? []
        customSkills = try c.decodeIfPresent(
            [BackupCustomSkill].self, forKey: .customSkills) ?? []
        disabledSkills = try c.decodeIfPresent([String].self, forKey: .disabledSkills) ?? []
    }
}
