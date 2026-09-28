import Foundation

// MARK: - 旅行共享(CloudKit)的纯逻辑

// 共享一趟旅行 = 在 owner 私有库里给它建一个 zone(`trip-<uuid>`),对整个 zone 建一个
// CKShare;成员从 shared database 拉。同步引擎(CKSyncEngine)在 app 层
// (`Lodo/Core/SharedTripSync.swift`),这里只放不碰 CloudKit 的部分——记录长什么样、
// 两边都改了怎么合并、本地改了哪些要推——`SharedTripSyncTests` 离线守着。
//
// 判断"这轮是谁改的"靠**账本**(上次对平时每条记录的字段值),和日历双向同步
// (`CalendarSyncLedger`)同一个思路:模型上没有 updatedAt,给十几个改动点逐个补
// 时间戳漏一处就会悄悄同步错方向。

/// 这台设备在一趟共享旅行里的身份。存进 `TravelTrip.shareRoleRaw`,空串 = 没共享。
public enum SharedTripRole: String, Codable, Sendable {
    case owner
    case participant
}

extension TravelTrip {
    public var shareRole: SharedTripRole? { SharedTripRole(rawValue: shareRoleRaw) }
    public var isShared: Bool { shareRole != nil }
}

/// CKRecord 的 recordType。**存储值别改**——它们就是 CloudKit schema 里的类型名。
public enum SharedRecordType: String, Codable, Sendable, CaseIterable {
    case trip = "Trip"
    /// 行程项和旅行文件本来就是同一种 `MemoryItem`,共用一个类型。
    case entry = "TripEntry"
    case packing = "PackingItem"
}

/// 一个字段的值。字段整份编码成 JSON 放进 CKRecord 的一个 `payload` 字段——合并在
/// 客户端按字段做(见 `SharedTripMerge`),用不上 CloudKit 自己的字段级类型,反倒
/// 省掉了 NSNumber 分不清 Bool/Int/Double 的麻烦。
public enum SharedFieldValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case strings([String])
}

/// 字段名 → 值;值为 nil 的字段不出现(合并时"没有这个键"就等于 nil)。
public typealias SharedFields = [String: SharedFieldValue]

/// 一条记录此刻的样子(本地从模型读出来,或者从服务器记录解出来)。
public struct SharedRecordSnapshot: Codable, Equatable, Sendable {
    public var type: SharedRecordType
    public var uuid: UUID
    public var fields: SharedFields

    public init(type: SharedRecordType, uuid: UUID, fields: SharedFields) {
        self.type = type
        self.uuid = uuid
        self.fields = fields
    }
}

// MARK: - 模型 ↔ 字段

public enum SharedTripMapping {
    public static let zonePrefix = "trip-"
    /// 单个附件超过这个大小就不上传(记录里仍然留着文件名,其他成员看到的是
    /// 「仅在添加者的设备上」)。
    public static let maxAssetBytes = 50 * 1024 * 1024

    public static func zoneName(for tripUUID: UUID) -> String {
        zonePrefix + tripUUID.uuidString
    }

    public static func tripUUID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count)))
    }

    public static func snapshot(of trip: TravelTrip) -> SharedRecordSnapshot {
        var f = SharedFields()
        f["title"] = .string(trip.title)
        f["startDate"] = .date(trip.startDate)
        f["endDate"] = .date(trip.endDate)
        f["notes"] = .string(trip.notes)
        f["city"] = .string(trip.city)
        f["country"] = .string(trip.country)
        f["extraDestinations"] = .string(trip.extraDestinations)
        f["emoji"] = .string(trip.emoji)
        f["createdAt"] = .date(trip.createdAt)
        return SharedRecordSnapshot(type: .trip, uuid: trip.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to trip: TravelTrip) {
        trip.title = f.string("title") ?? ""
        trip.startDate = f.date("startDate") ?? trip.startDate
        trip.endDate = f.date("endDate") ?? trip.endDate
        trip.notes = f.string("notes") ?? ""
        trip.city = f.string("city") ?? ""
        trip.country = f.string("country") ?? ""
        trip.extraDestinations = f.string("extraDestinations") ?? ""
        trip.emoji = f.string("emoji") ?? ""
        trip.createdAt = f.date("createdAt") ?? trip.createdAt
    }

    /// 行程项/旅行文件。标签不同步(收到的一端本地打「旅行」),`sharedAddedBy`
    /// 也不同步(由收到的一端按记录的创建者算)。
    public static func snapshot(of item: MemoryItem) -> SharedRecordSnapshot {
        var f = SharedFields()
        f["kindRaw"] = .string(item.kindRaw)
        f["title"] = .string(item.title)
        f["summary"] = .string(item.summary)
        f["sourceText"] = .string(item.sourceText)
        f["urlString"] = item.urlString.map { .string($0) }
        f["originalFileName"] = item.originalFileName.map { .string($0) }
        f["relativeFilePath"] = item.relativeFilePath.map { .string($0) }
        if !item.attachmentRelativePaths.isEmpty {
            f["attachmentRelativePaths"] = .strings(item.attachmentRelativePaths)
        }
        f["statusRaw"] = .string(item.statusRaw)
        f["createdAt"] = .date(item.createdAt)
        f["travelKindRaw"] = item.travelKindRaw.map { .string($0) }
        f["travelStart"] = item.travelStart.map { .date($0) }
        f["travelEnd"] = item.travelEnd.map { .date($0) }
        f["travelPrice"] = item.travelPrice.map { .double($0) }
        f["travelCurrency"] = item.travelCurrency.map { .string($0) }
        f["travelPlaceName"] = item.travelPlaceName.map { .string($0) }
        f["travelLatitude"] = item.travelLatitude.map { .double($0) }
        f["travelLongitude"] = item.travelLongitude.map { .double($0) }
        f["travelOriginName"] = item.travelOriginName.map { .string($0) }
        f["travelOriginLatitude"] = item.travelOriginLatitude.map { .double($0) }
        f["travelOriginLongitude"] = item.travelOriginLongitude.map { .double($0) }
        f["travelCode"] = item.travelCode.map { .string($0) }
        f["travelFlightData"] = item.travelFlightData.map { .data($0) }
        return SharedRecordSnapshot(type: .entry, uuid: item.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to item: MemoryItem) {
        item.kindRaw = f.string("kindRaw") ?? MemoryKind.text.rawValue
        item.title = f.string("title") ?? ""
        item.summary = f.string("summary") ?? ""
        item.sourceText = f.string("sourceText") ?? ""
        item.urlString = f.string("urlString")
        item.originalFileName = f.string("originalFileName")
        item.relativeFilePath = f.string("relativeFilePath")
        item.attachmentRelativePaths = f.strings("attachmentRelativePaths") ?? []
        item.statusRaw = f.string("statusRaw") ?? MemoryStatus.ready.rawValue
        item.createdAt = f.date("createdAt") ?? item.createdAt
        item.travelKindRaw = f.string("travelKindRaw")
        item.travelStart = f.date("travelStart")
        item.travelEnd = f.date("travelEnd")
        item.travelPrice = f.double("travelPrice")
        item.travelCurrency = f.string("travelCurrency")
        item.travelPlaceName = f.string("travelPlaceName")
        item.travelLatitude = f.double("travelLatitude")
        item.travelLongitude = f.double("travelLongitude")
        item.travelOriginName = f.string("travelOriginName")
        item.travelOriginLatitude = f.double("travelOriginLatitude")
        item.travelOriginLongitude = f.double("travelOriginLongitude")
        item.travelCode = f.string("travelCode")
        item.travelFlightData = f.data("travelFlightData")
        if !item.tags.contains(MemoryItem.travelTagName) {
            item.tags.append(MemoryItem.travelTagName)
        }
    }

    public static func snapshot(of item: PackingItem) -> SharedRecordSnapshot {
        var f = SharedFields()
        f["title"] = .string(item.title)
        f["category"] = .string(item.category)
        f["packed"] = .bool(item.packed)
        f["sortIndex"] = .int(item.sortIndex)
        f["createdAt"] = .date(item.createdAt)
        return SharedRecordSnapshot(type: .packing, uuid: item.uuid, fields: f)
    }

    public static func apply(_ f: SharedFields, to item: PackingItem) {
        item.title = f.string("title") ?? ""
        item.category = f.string("category") ?? ""
        item.packed = f.bool("packed") ?? false
        item.sortIndex = f.int("sortIndex") ?? 0
        item.createdAt = f.date("createdAt") ?? item.createdAt
    }

    /// CKRecord 的 `payload` 字段:整份字段的 JSON。
    public static func encode(_ fields: SharedFields) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(fields)
    }

    public static func decode(_ data: Data) -> SharedFields? {
        try? JSONDecoder().decode(SharedFields.self, from: data)
    }
}

extension Dictionary where Key == String, Value == SharedFieldValue {
    func string(_ key: String) -> String? {
        if case .string(let v) = self[key] { return v }
        return nil
    }
    func date(_ key: String) -> Date? {
        if case .date(let v) = self[key] { return v }
        return nil
    }
    func double(_ key: String) -> Double? {
        switch self[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    func int(_ key: String) -> Int? {
        switch self[key] {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    func bool(_ key: String) -> Bool? {
        if case .bool(let v) = self[key] { return v }
        return nil
    }
    func data(_ key: String) -> Data? {
        if case .data(let v) = self[key] { return v }
        return nil
    }
    func strings(_ key: String) -> [String]? {
        if case .strings(let v) = self[key] { return v }
        return nil
    }
}

// MARK: - 合并

public enum SharedTripMerge {
    /// 按字段三方合并:只有一方改过的字段取那一方;**两方都改了同一个字段时
    /// 服务器赢**(先提交的人赢,和 CloudKit 的 serverRecordChanged 语义一致)。
    /// 没有 base(这台设备从没对平过这条)时一律服务器赢。
    public static func merge(base: SharedFields?, local: SharedFields,
                             server: SharedFields) -> SharedFields {
        guard let base else { return server }
        var merged = SharedFields()
        for key in Set(local.keys).union(server.keys).union(base.keys) {
            let localChanged = local[key] != base[key]
            let serverChanged = server[key] != base[key]
            let value = (localChanged && !serverChanged) ? local[key] : server[key]
            if let value { merged[key] = value }
        }
        return merged
    }
}

// MARK: - 账本

/// 账本里的一条:上次对平时服务器上这条记录的字段,外加 CloudKit 的系统字段
/// (recordChangeTag 等,`encodeSystemFields` 的结果)——下次保存要带着它,
/// 服务器才知道我们是在哪个版本上改的。
public struct SharedLedgerRecord: Codable, Equatable, Sendable {
    public var type: SharedRecordType
    public var fields: SharedFields
    public var systemFields: Data?

    public init(type: SharedRecordType, fields: SharedFields, systemFields: Data? = nil) {
        self.type = type
        self.fields = fields
        self.systemFields = systemFields
    }
}

/// 一趟共享旅行(一个 zone)的账本。
public struct SharedZoneLedger: Codable, Equatable, Sendable {
    public var zoneName: String
    /// zone 的 owner(`CKRecordZone.ID.ownerName`);自己是 owner 时是
    /// `CKCurrentUserDefaultName`。
    public var ownerName: String
    public var role: SharedTripRole
    public var tripUUID: UUID
    public var records: [UUID: SharedLedgerRecord]

    public init(zoneName: String, ownerName: String, role: SharedTripRole, tripUUID: UUID,
                records: [UUID: SharedLedgerRecord] = [:]) {
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.role = role
        self.tripUUID = tripUUID
        self.records = records
    }

    public var key: String { Self.key(zoneName: zoneName, ownerName: ownerName) }

    public static func key(zoneName: String, ownerName: String) -> String {
        ownerName + "|" + zoneName
    }
}

// MARK: - 计划

public struct SharedPushPlan: Equatable, Sendable {
    public var saves: [UUID]
    public var deletes: [UUID]

    public init(saves: [UUID] = [], deletes: [UUID] = []) {
        self.saves = saves
        self.deletes = deletes
    }

    public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

public enum SharedIncomingAction: Equatable, Sendable {
    /// 本地没有、也从没对平过:新建。
    case insert(SharedFields)
    /// 本地有:写入合并后的字段。
    case update(SharedFields)
    /// 本地已经删了、删除还没推上去:删除赢,不复活。
    case skipDeletedLocally
}

public enum SharedTripPlanner {
    /// 本地 → 服务器:和账本比,字段变了(或账本里没有)的要存,账本里有、本地
    /// 没有的要删。结果按 uuid 排好,方便测试和日志。
    public static func pushPlan(local: [SharedRecordSnapshot],
                                ledger: [UUID: SharedLedgerRecord]) -> SharedPushPlan {
        var plan = SharedPushPlan()
        var seen = Set<UUID>()
        for snapshot in local {
            seen.insert(snapshot.uuid)
            if ledger[snapshot.uuid]?.fields != snapshot.fields {
                plan.saves.append(snapshot.uuid)
            }
        }
        plan.deletes = ledger.keys.filter { !seen.contains($0) }
        plan.saves.sort { $0.uuidString < $1.uuidString }
        plan.deletes.sort { $0.uuidString < $1.uuidString }
        return plan
    }

    /// 服务器 → 本地,一条记录。
    public static func incoming(server: SharedFields, base: SharedFields?,
                                local: SharedFields?) -> SharedIncomingAction {
        guard let local else {
            return base == nil ? .insert(server) : .skipDeletedLocally
        }
        return .update(SharedTripMerge.merge(base: base, local: local, server: server))
    }

    /// 同一个 uuid 出现了多行(成员的两台设备各自落了一行,再经私有库镜像
    /// 汇到一起):留第一行,其余返回给调用方删掉。
    public static func duplicates<T>(_ items: [T], uuid: (T) -> UUID) -> [T] {
        var seen = Set<UUID>()
        return items.filter { !seen.insert(uuid($0)).inserted }
    }
}

// MARK: - 账本文件

/// 落 Application Support 的 JSON(理由同 `CalendarSyncLedger`:可重算的本机派生
/// 数据,**不跨设备同步**——系统字段、引擎状态都是每台设备各自的)。
public enum SharedTripLedger {
    public enum Scope: String, Codable, Sendable {
        case privateDatabase
        case sharedDatabase
    }

    private struct File: Codable {
        var zones: [String: SharedZoneLedger] = [:]
        var engineStates: [String: Data] = [:]
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "shared-trip-ledger.json")
    }

    private static func load() -> File {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return value
    }

    private static func store(_ file: File) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public static var zones: [String: SharedZoneLedger] { load().zones }

    public static func saveZones(_ zones: [String: SharedZoneLedger]) {
        var file = load()
        file.zones = zones
        store(file)
    }

    public static func engineState(for scope: Scope) -> Data? {
        load().engineStates[scope.rawValue]
    }

    public static func saveEngineState(_ data: Data?, for scope: Scope) {
        var file = load()
        file.engineStates[scope.rawValue] = data
        store(file)
    }

    /// 换了 iCloud 账号 / 登出:账本和引擎状态都不再对得上,整份清掉。
    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
