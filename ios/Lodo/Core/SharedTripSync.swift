import Foundation
import SwiftData
import CloudKit
import Observation
import OSLog
import LodoCore

/// 旅行共享(仅 iOS/macOS 主 app):把用户主动共享的旅行经 CKSyncEngine 同步给成员。
///
/// - 每趟共享旅行在 owner 私有库里一个 zone(`trip-<uuid>`),整个 zone 一个 CKShare;
///   成员那边从 shared database 拉。两个引擎:`privateEngine` 管我分享出去的,
///   `sharedEngine` 管别人分享给我的。没共享的旅行完全不进这一层,其余数据照旧走
///   SwiftData 自己的私有库同步。
/// - **本地改动不逐处挂钩子**:监听 `ModelContext.didSave`,合并后整趟对账
///   (本地快照 vs 账本,见 `SharedTripPlanner.pushPlan`)。表单、AI 的
///   edit_trip/plan_trip、导入、清单、文件全都自动覆盖——理由同 `CalendarSync`。
/// - **远端改动**按 uuid 写回 SwiftData,写的期间置 `applying`,这次保存不会再被
///   当成本地改动推回去。
/// - 私有库里 SwiftData 自己的镜像 zone(`com.apple.coredata.cloudkit.zone`)也会被
///   私有库引擎拉到,不是 `trip-` / `assets-` 开头的 zone 一律忽略。
/// - **资产台账共享**(2026-09)走同一套引擎和账本:整本台账一个 `assets-<台账 uuid>`
///   zone,资产条目/收支条目靠自己身上的台账标记归属(规则见 `SharedAssetPlanner.joins`)。
///   名字仍叫 SharedTripSync 是历史原因——两种共享共用一对引擎,一个数据库不该挂两个
///   CKSyncEngine(各自拉全部 zone、各自存一份 change token)。
@MainActor
@Observable
final class SharedTripSync {
    static let shared = SharedTripSync()
    static let containerID = "iCloud.com.lodo.app"

    /// 登录了 iCloud、引擎起来了。没登录时共享菜单项置灰。
    private(set) var isAvailable = false
    /// 每趟共享旅行还没推上去的改动数(面板顶部「正在同步 N 项」)。
    private(set) var pendingCounts: [UUID: Int] = [:]
    /// 接受邀请、拉完数据后要打开的旅行(`AppShellView` 接走并置回 nil)。
    var openTripRequest: UUID?
    /// 接受了资产台账的邀请:打开资产页(`AppShellView` 接走并置回 false)。
    var openAssetsRequest = false
    /// 接受了聊天室邀请:要打开的房间(AI 助手页接走并置回 nil)。
    var openChatRequest: UUID?

    /// 这台设备上的共享资产台账(没共享为 nil)。一台设备只有一本:自己分享出去的,
    /// 或者加入的别人那本。
    struct AssetShareState: Equatable {
        var ledgerUUID: UUID
        var role: SharedTripRole
    }
    private(set) var assetShare: AssetShareState?
    /// 最近一次失败的说明(共享菜单/面板上如实报)。
    var lastError: String?

    /// 共享相关的失败都经这里:写日志(Console.app 里按 subsystem com.lodo.app、
    /// category SharedTrip 过滤)并交给界面显示。系统共享界面的报错原来只存不显示,
    /// 用户只看到"发不出去"。
    static let log = Logger(subsystem: "com.lodo.app", category: "SharedTrip")

    func report(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        lastError = message
    }

    /// 错误里带着 retryAfter 就记下限流截止时间(也认 partialFailure 里包着的)。
    private func noteThrottle(_ error: Error) {
        guard let error = error as? CKError else { return }
        let seconds = error.retryAfterSeconds
            ?? error.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.retryAfterSeconds }.max()
        guard let seconds else { return }
        let until = Date().addingTimeInterval(seconds)
        if until > (throttledUntil ?? .distantPast) { throttledUntil = until }
        Self.log.notice("CloudKit throttled for \(Int(seconds))s")
    }

    /// 还在限流期内时剩几分钟(向上取整),不限流为 nil。
    private var throttleMinutesLeft: Int? {
        guard let until = throttledUntil, until > Date() else { return nil }
        return max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
    }

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private var ckContainer: CKContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    /// 这次启动里已经补救过一次(重建 zone / 丢系统字段重存)的记录和 zone,
    /// 再失败就报错停手,不再重排——见 handleSent。
    @ObservationIgnored private var retriedRecords: Set<CKRecord.ID> = []
    @ObservationIgnored private var recreatedZones: Set<CKRecordZone.ID> = []
    /// 服务器限流(503 / requestRateLimited 带 retryAfter)到什么时候。期间不发任何
    /// 手动请求(回前台拉取、发起共享),引擎自己的重试由它按 retryAfter 退避。
    @ObservationIgnored private var throttledUntil: Date?

    /// 共享成员:userRecordID.recordName → 显示名,给「由 X 添加」用。按 zone 缓存。
    @ObservationIgnored private var participantNames: [String: [String: String]] = [:]

    private init() {}

    private var context: ModelContext? { modelContainer?.mainContext }

    // MARK: - 启动

    func configure(container: ModelContainer) {
        guard modelContainer == nil else { return }
        modelContainer = container
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SharedTripSync.shared.scheduleReconcile() }
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Task { await SharedTripSync.shared.start() } }
        }
        Task { await start() }
    }

    /// 查 iCloud 账号,可用就把两个引擎起来。可以重复调(账号变化、接受邀请时)。
    func start() async {
        if ckContainer == nil { ckContainer = CKContainer(identifier: Self.containerID) }
        guard let ckContainer else { return }
        let status = (try? await ckContainer.accountStatus()) ?? .couldNotDetermine
        isAvailable = status == .available
        refreshAssetShare(SharedTripLedger.zones)
        guard isAvailable, privateEngine == nil else { return }
        privateEngine = CKSyncEngine(configuration(ckContainer.privateCloudDatabase, scope: .privateDatabase))
        sharedEngine = CKSyncEngine(configuration(ckContainer.sharedCloudDatabase, scope: .sharedDatabase))
        reconcile()
    }

    private func configuration(_ database: CKDatabase,
                               scope: SharedTripLedger.Scope) -> CKSyncEngine.Configuration {
        let state = SharedTripLedger.engineState(for: scope).flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        return CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
    }

    /// 回前台时调:主动拉一次(推送不一定每条都到)。
    func refresh() {
        guard isAvailable else {
            Task { await start() }
            return
        }
        reconcile()
        // 限流期内不再手动拉:每次回前台都补一枪,正是把限流越拖越长的那种请求。
        guard throttleMinutesLeft == nil else { return }
        Task {
            do { try await privateEngine?.fetchChanges() } catch { noteThrottle(error) }
            do { try await sharedEngine?.fetchChanges() } catch { noteThrottle(error) }
        }
    }

    // MARK: - 共享 / 退出

    enum ShareError: LocalizedError {
        case unavailable
        /// 服务器没回来存好的 share(结果里既没有成功也没有错误)。
        case notSaved
        /// 自己是成员,但 owner 那边的共享已经没了。
        case gone
        /// iCloud 服务器限流中,还要等几分钟。
        case throttled(minutes: Int)

        var errorDescription: String? {
            switch self {
            case .throttled(let minutes):
                return String(localized: "iCloud 暂时限流,约 \(minutes) 分钟后再试", bundle: .appLanguage())
            case .unavailable:
                return String(localized: "请先在系统设置里登录 iCloud", bundle: .appLanguage())
            case .notSaved:
                return String(localized: "共享没有存到 iCloud,请稍后再试", bundle: .appLanguage())
            case .gone:
                return String(localized: "这次共享已经不存在了,本地保留了一份副本", bundle: .appLanguage())
            }
        }
    }

    /// 发起共享(已共享时取回现有的 share),给系统共享界面用。
    ///
    /// **`modifyRecordZones`/`modifyRecords` 单条失败时不抛错**,错误在返回结果里——
    /// 必须逐条 `get()`。早先的写法没查结果:zone/share 其实没存上,旅行却被标成了
    /// 已共享,系统界面拿着一份没存上的 share 弹得出来却发不出去,之后再点又因为
    /// "已共享"去取 share,报 Zone does not exist。
    func prepareShare(for trip: TravelTrip) async throws -> CKShare {
        if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
        do {
            return try await createOrFetchShare(for: trip)
        } catch {
            noteThrottle(error)
            if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
            throw error
        }
    }

    private func createOrFetchShare(for trip: TravelTrip) async throws -> CKShare {
        if !isAvailable { await start() }
        guard isAvailable, let ckContainer else { throw ShareError.unavailable }
        if trip.isShared {
            do {
                if let existing = try await fetchShare(for: trip) {
                    await loadParticipants(existing)
                    return existing
                }
            } catch where Self.isMissing(error) {
                // 本地标着已共享、服务器上却没有:清掉本地标记。owner 接着往下重建;
                // 成员没法替 owner 重建,改回不共享的副本并如实说明。
                Self.log.notice("trip \(trip.uuid, privacy: .public) marked shared but zone/share missing; resetting")
                let wasParticipant = trip.shareRole == .participant
                dropLocalShare(trip)
                if wasParticipant { throw ShareError.gone }
            }
        }
        let zoneID = CKRecordZone.ID(zoneName: SharedTripMapping.zoneName(for: trip.uuid),
                                     ownerName: CKCurrentUserDefaultName)
        let saved = try await saveZoneAndShare(zoneID, title: trip.title, container: ckContainer)
        Self.log.info("trip \(trip.uuid, privacy: .public) shared, url=\(saved.url?.absoluteString ?? "nil", privacy: .public)")

        applying = true
        trip.shareRoleRaw = SharedTripRole.owner.rawValue
        trip.shareZoneOwner = CKCurrentUserDefaultName
        try? context?.save()
        applying = false

        var zones = SharedTripLedger.zones
        let ledger = SharedZoneLedger(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
                                      role: .owner, tripUUID: trip.uuid)
        zones[ledger.key] = ledger
        saveZones(zones)
        // 已有的行程、文件、清单全量排队上传。
        reconcile()
        return saved
    }

    /// 在私有库里建 zone + zone-wide share(zone 已有 share 就直接用)。旅行和资产台账共用。
    private func saveZoneAndShare(_ zoneID: CKRecordZone.ID, title: String,
                                  container ckContainer: CKContainer) async throws -> CKShare {
        let database = ckContainer.privateCloudDatabase
        let zoneResult = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        _ = try zoneResult.saveResults[zoneID]?.get()

        // zone 里可能已经有一份 share(上次存上了、本地标记却丢了):直接用它,再存一份
        // 新的 zone-wide share 会撞 serverRecordChanged。
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare {
            return existing
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard let stored = try result.saveResults[share.recordID]?.get() as? CKShare else {
            throw ShareError.notSaved
        }
        return stored
    }

    // MARK: - 资产台账共享

    /// 发起资产台账共享(已共享 / 已加入时取回现有的 share),给系统共享界面用。
    /// 第一次共享时整本台账(全部资产、收入、支出、信用卡)排队上传。
    func prepareAssetShare() async throws -> CKShare {
        if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
        do {
            return try await createOrFetchAssetShare()
        } catch {
            noteThrottle(error)
            if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
            throw error
        }
    }

    private func createOrFetchAssetShare() async throws -> CKShare {
        if !isAvailable { await start() }
        guard isAvailable, let ckContainer else { throw ShareError.unavailable }
        var ledgerUUID = UUID()
        if let entry = assetZoneEntry() {
            let zoneID = CKRecordZone.ID(zoneName: entry.zoneName, ownerName: entry.ownerName)
            let database = entry.role == .owner
                ? ckContainer.privateCloudDatabase : ckContainer.sharedCloudDatabase
            let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            do {
                if let existing = try await database.record(for: id) as? CKShare {
                    await loadParticipants(existing)
                    return existing
                }
            } catch where Self.isMissing(error) {
                // 同旅行那条:本地标着共享、服务器上没有。成员没法替 owner 重建。
                Self.log.notice("asset ledger marked shared but zone/share missing; resetting")
                dropAssetZone(entry, deleteOnServer: false)
                if entry.role == .participant { throw ShareError.gone }
            }
            // owner 重建时沿用原来的台账 uuid:条目上的标记还指着它。
            if entry.role == .owner { ledgerUUID = entry.containerUUID }
        }
        let zoneID = CKRecordZone.ID(zoneName: SharedAssetMapping.zoneName(for: ledgerUUID),
                                     ownerName: CKCurrentUserDefaultName)
        let saved = try await saveZoneAndShare(
            zoneID, title: String(localized: "资产", bundle: .appLanguage()), container: ckContainer)
        Self.log.info("asset ledger \(ledgerUUID, privacy: .public) shared, url=\(saved.url?.absoluteString ?? "nil", privacy: .public)")
        var zones = SharedTripLedger.zones
        if zones[SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)] == nil {
            let ledger = SharedZoneLedger(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
                                          role: .owner, tripUUID: ledgerUUID)
            zones[ledger.key] = ledger
            saveZones(zones)
        }
        // 条目不自动加入:共享哪些由调用方(确认页)接着 `applyAssetSelection` 挂标记。
        return saved
    }

    /// 系统共享界面里停止共享 / 退出之后:删 zone(owner)或退出(成员),本地条目
    /// 留着、摘掉共享标记。
    func didStopSharingAssets() {
        guard let entry = assetZoneEntry() else { return }
        dropAssetZone(entry, deleteOnServer: true)
    }

    /// 确认页里勾选的结果:挂上 / 摘掉共享标记,保存后由 didSave → 对账推上去。
    /// 摘掉的那几条在服务器上删除,其他成员那边随之删掉他们的副本(见 applyDeletions)。
    func applyAssetSelection(add: Set<UUID>, remove: Set<UUID>) {
        guard let context, let ledgerUUID = assetShare?.ledgerUUID,
              !(add.isEmpty && remove.isEmpty) else { return }
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for item in items where item.isAsset {
            if add.contains(item.uuid) { item.assetLedgerUUID = ledgerUUID }
            if remove.contains(item.uuid), item.assetLedgerUUID == ledgerUUID { item.assetLedgerUUID = nil }
        }
        let entries = (try? context.fetch(FetchDescriptor<FinanceEntry>())) ?? []
        for entry in entries {
            if add.contains(entry.uuid) { entry.ledgerUUID = ledgerUUID }
            if remove.contains(entry.uuid), entry.ledgerUUID == ledgerUUID { entry.ledgerUUID = nil }
        }
        try? context.save()
        reconcile()
    }

    /// 共享台账里别人加的条目:确认页上锁住、不能从这台设备移出共享。
    func assetUUIDsAddedByOthers() -> Set<UUID> {
        guard let entry = assetZoneEntry() else { return [] }
        return Set(entry.records.compactMap { uuid, record in
            createdByMe(record) == false ? uuid : nil
        })
    }

    /// 共享成员(确认页上「当前状态」那一段用)。
    struct AssetShareMember: Identifiable, Equatable {
        let id: String
        let name: String
        let isOwner: Bool
        let isMe: Bool
        let accepted: Bool
    }

    func assetShareMembers() async -> [AssetShareMember] {
        guard let ckContainer, let entry = assetZoneEntry() else { return [] }
        let zoneID = CKRecordZone.ID(zoneName: entry.zoneName, ownerName: entry.ownerName)
        let database = entry.role == .owner ? ckContainer.privateCloudDatabase : ckContainer.sharedCloudDatabase
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try? await database.record(for: id) as? CKShare else { return [] }
        await loadParticipants(share)
        let me = share.currentUserParticipant
        return share.participants.enumerated().map { index, participant in
            let identity = participant.userIdentity
            let name = identity.nameComponents.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }.flatMap { $0.isEmpty ? nil : $0 }
                ?? identity.lookupInfo?.emailAddress
                ?? identity.lookupInfo?.phoneNumber
                ?? String(localized: "未知成员", bundle: .appLanguage())
            return AssetShareMember(
                id: identity.userRecordID?.recordName ?? "\(index)",
                name: name,
                isOwner: participant.role == .owner,
                isMe: participant == me,
                accepted: participant.acceptanceStatus == .accepted)
        }
    }

    private func assetZoneEntry() -> SharedZoneLedger? {
        SharedTripLedger.zones.values.first { $0.kind == .assets }
    }

    private func dropAssetZone(_ entry: SharedZoneLedger, deleteOnServer: Bool) {
        var zones = SharedTripLedger.zones
        if deleteOnServer {
            let zoneID = CKRecordZone.ID(zoneName: entry.zoneName, ownerName: entry.ownerName)
            engine(for: entry.role)?.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        }
        zones[entry.key] = nil
        saveZones(zones)
        clearAssetMarkers(entry.containerUUID)
    }

    /// 摘掉某本台账的标记:条目本身留在本机,成了不共享的一份。
    private func clearAssetMarkers(_ ledgerUUID: UUID) {
        guard let context else { return }
        applying = true
        defer { applying = false }
        assetItems(in: ledgerUUID, context: context).forEach { $0.assetLedgerUUID = nil }
        financeEntries(in: ledgerUUID, context: context).forEach { $0.ledgerUUID = nil }
        try? context.save()
        pendingCounts[ledgerUUID] = nil
    }

    private func saveZones(_ zones: [String: SharedZoneLedger]) {
        SharedTripLedger.saveZones(zones)
        refreshAssetShare(zones)
    }

    private func refreshAssetShare(_ zones: [String: SharedZoneLedger]) {
        let state = zones.values.first { $0.kind == .assets }
            .map { AssetShareState(ledgerUUID: $0.containerUUID, role: $0.role) }
        if state != assetShare { assetShare = state }
    }

    private func fetchShare(for trip: TravelTrip) async throws -> CKShare? {
        guard let ckContainer, let role = trip.shareRole else { return nil }
        let database = role == .owner ? ckContainer.privateCloudDatabase : ckContainer.sharedCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: SharedTripMapping.zoneName(for: trip.uuid),
                                     ownerName: trip.shareZoneOwner.isEmpty
                                        ? CKCurrentUserDefaultName : trip.shareZoneOwner)
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        return try await database.record(for: id) as? CKShare
    }

    /// zone 或 share 在服务器上不存在(也认 partialFailure 里包着的那种)。
    private static func isMissing(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .zoneNotFound, .unknownItem, .userDeletedZone:
            return true
        case .partialFailure:
            return error.partialErrorsByItemID?.values.contains { isMissing($0) } ?? false
        default:
            return false
        }
    }

    /// 只清本地:账本里这趟的 zone 记录 + 旅行上的共享标记。不动服务器(本来就没有)。
    private func dropLocalShare(_ trip: TravelTrip) {
        var zones = SharedTripLedger.zones
        for entry in zones.values where entry.tripUUID == trip.uuid {
            zones[entry.key] = nil
        }
        saveZones(zones)
        markUnshared(trip)
    }

    /// 系统共享界面里 owner 停止共享 / 成员把自己移除之后:本地数据留着,改回
    /// 没共享的一份副本。owner 顺手删掉 zone(不然白占 iCloud 空间),成员删掉
    /// shared database 里那个 zone = 退出。
    func didStopSharing(_ trip: TravelTrip) {
        var zones = SharedTripLedger.zones
        if let entry = zones.values.first(where: { $0.tripUUID == trip.uuid }) {
            let zoneID = CKRecordZone.ID(zoneName: entry.zoneName, ownerName: entry.ownerName)
            engine(for: entry.role)?.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
            zones[entry.key] = nil
            saveZones(zones)
        }
        markUnshared(trip)
    }

    /// 接受邀请(系统在用户点了共享链接后回调 scene delegate)。
    func accept(_ metadata: CKShare.Metadata) async {
        if !isAvailable { await start() }
        guard let ckContainer else { return }
        let zoneID = metadata.share.recordID.zoneID
        guard let kind = SharedZoneKind(zoneName: zoneID.zoneName),
              let containerUUID = SharedZoneKind.containerUUID(fromZoneName: zoneID.zoneName) else { return }
        func open() {
            switch kind {
            case .trip: openTripRequest = containerUUID
            case .assets: openAssetsRequest = true
            case .chat: openChatRequest = containerUUID
            }
        }
        // 自己点开自己分享出去的链接:什么都不用接,直接打开。
        if metadata.participantRole == .owner {
            open()
            return
        }
        // 一台设备只接一本共享资产台账:已经有一本(自己分享出去的或加入的别人的)时,
        // 新条目该进哪本就说不清了。
        if kind == .assets, let existing = assetZoneEntry(),
           existing.zoneName != zoneID.zoneName || existing.ownerName != zoneID.ownerName {
            report(String(localized: "已经在共享一本资产台账了,先停止共享或退出那一本再加入", bundle: .appLanguage()))
            return
        }
        do {
            _ = try await ckContainer.accept(metadata)
        } catch {
            report(error.localizedDescription)
            return
        }
        register(zoneID, role: .participant)
        await loadParticipants(metadata.share)
        try? await sharedEngine?.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        open()
    }

    // MARK: - 共享聊天室

    /// 自己在共享成员表里的名字(取到过一次就记在本机)。发消息时写进 payload 兜底:
    /// 收到的一端成员表还没取到时也有个名字可显示。
    static var myDisplayName: String {
        get { UserDefaults.standard.string(forKey: "chatMyDisplayName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chatMyDisplayName") }
    }

    /// 新建一个聊天室:先落本地,再在 iCloud 上建 zone + share(建不起来——没登录、
    /// 限流——房间照样在,第一次点「邀请」时再建)。
    @discardableResult
    func createRoom(title: String) -> ChatRoom? {
        guard let context else { return nil }
        let room = ChatRoom(title: title)
        context.insert(room)
        try? context.save()
        Task { _ = try? await prepareChatShare(for: room) }
        return room
    }

    /// 发起邀请(已共享时取回现有的 share),给系统共享界面用。
    func prepareChatShare(for room: ChatRoom) async throws -> CKShare {
        if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
        do {
            return try await createOrFetchChatShare(for: room)
        } catch {
            noteThrottle(error)
            if let minutes = throttleMinutesLeft { throw ShareError.throttled(minutes: minutes) }
            throw error
        }
    }

    private func createOrFetchChatShare(for room: ChatRoom) async throws -> CKShare {
        if !isAvailable { await start() }
        guard isAvailable, let ckContainer else { throw ShareError.unavailable }
        if let role = room.shareRole {
            let database = role == .owner ? ckContainer.privateCloudDatabase : ckContainer.sharedCloudDatabase
            let zoneID = CKRecordZone.ID(zoneName: SharedChatMapping.zoneName(for: room.uuid),
                                         ownerName: room.shareZoneOwner.isEmpty
                                            ? CKCurrentUserDefaultName : room.shareZoneOwner)
            let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            do {
                if let existing = try await database.record(for: id) as? CKShare {
                    await loadParticipants(existing)
                    return existing
                }
            } catch where Self.isMissing(error) {
                // 成员这边服务器上已经没有了:房间已被销毁,本地跟着删掉。
                if role == .participant {
                    dropChatZone(room.uuid, deleteOnServer: false)
                    throw ShareError.gone
                }
                Self.log.notice("chat \(room.uuid, privacy: .public) marked shared but zone/share missing; recreating")
            }
        }
        let zoneID = CKRecordZone.ID(zoneName: SharedChatMapping.zoneName(for: room.uuid),
                                     ownerName: CKCurrentUserDefaultName)
        let saved = try await saveZoneAndShare(zoneID, title: room.title, container: ckContainer)
        await loadParticipants(saved)
        applying = true
        room.shareRoleRaw = SharedTripRole.owner.rawValue
        room.shareZoneOwner = CKCurrentUserDefaultName
        try? context?.save()
        applying = false

        var zones = SharedTripLedger.zones
        let ledger = SharedZoneLedger(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
                                      role: .owner, tripUUID: room.uuid)
        if zones[ledger.key] == nil { zones[ledger.key] = ledger }
        saveZones(zones)
        reconcile()
        return saved
    }

    /// 发一条消息:落本地,didSave → 对账推上去。
    func send(_ text: String, kind: ChatMessageKind = .text, in room: ChatRoom) {
        insertMessage(text, kind: kind, card: nil, in: room)
    }

    /// 分享一张内容卡片。
    func send(_ card: ChatCard, in room: ChatRoom) {
        insertMessage(card.summaryLine, kind: .card, card: card, in: room)
    }

    private func insertMessage(_ text: String, kind: ChatMessageKind, card: ChatCard?, in room: ChatRoom) {
        guard let context else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = ChatRoomMessage(roomUUID: room.uuid, kind: kind, content: trimmed,
                                      senderHint: Self.myDisplayName, fromMe: true)
        message.cardData = card?.encoded
        context.insert(message)
        room.lastMessageAt = message.createdAt
        room.lastReadAt = message.createdAt
        try? context.save()
    }

    /// 一份内容如果**已经**经 CloudKit 共享(共享旅行、共享资产台账里的条目),返回那份
    /// 共享的链接,卡片上给收到的人「加入共享」。没共享的不替用户新建共享——分享进聊天
    /// 的只是一份快照;要一起编辑,先在旅行/资产页里共享出去。取不到(离线、限流)也返回 nil。
    func existingShareURL(for reference: AgentReference) async -> URL? {
        guard let context, isAvailable else { return nil }
        let id = reference.id
        switch reference.kind {
        case .trip:
            guard let trip = fetchTrip(id, context: context), trip.isShared else { return nil }
            return try? await fetchShare(for: trip)?.url
        case .asset:
            guard fetchEntry(id, context: context)?.assetLedgerUUID != nil else { return nil }
            return try? await prepareAssetShare().url
        case .finance:
            guard fetchFinance(id, context: context)?.ledgerUUID != nil else { return nil }
            return try? await prepareAssetShare().url
        default:
            return nil
        }
    }

    /// 创建者销毁(删服务器上的 zone,所有成员的房间随之删除)/ 成员退出(删 shared
    /// database 里的 zone = 退出)。两种情况本地这一份都删掉。
    func destroyOrLeave(_ room: ChatRoom) {
        dropChatZone(room.uuid, deleteOnServer: true)
    }

    /// 系统共享界面里停止共享 / 把自己移除之后:同销毁/退出。聊天室没有共享就没有意义。
    func didStopSharing(_ room: ChatRoom) {
        dropChatZone(room.uuid, deleteOnServer: true)
    }

    private func dropChatZone(_ roomUUID: UUID, deleteOnServer: Bool) {
        var zones = SharedTripLedger.zones
        for entry in zones.values where entry.kind == .chat && entry.containerUUID == roomUUID {
            if deleteOnServer {
                let zoneID = CKRecordZone.ID(zoneName: entry.zoneName, ownerName: entry.ownerName)
                engine(for: entry.role)?.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
            }
            zones[entry.key] = nil
        }
        saveZones(zones)
        deleteLocalRoom(roomUUID)
    }

    private func deleteLocalRoom(_ roomUUID: UUID) {
        guard let context else { return }
        applying = true
        defer { applying = false }
        let rooms = (try? context.fetch(FetchDescriptor<ChatRoom>(
            predicate: #Predicate { $0.uuid == roomUUID }))) ?? []
        rooms.forEach(context.delete)
        chatMessages(in: roomUUID, context: context).forEach(context.delete)
        try? context.save()
        pendingCounts[roomUUID] = nil
    }

    private func fetchRoom(_ uuid: UUID, context: ModelContext) -> ChatRoom? {
        try? context.fetch(FetchDescriptor<ChatRoom>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func fetchChatMessage(_ uuid: UUID, context: ModelContext) -> ChatRoomMessage? {
        try? context.fetch(FetchDescriptor<ChatRoomMessage>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func chatMessages(in roomUUID: UUID, context: ModelContext) -> [ChatRoomMessage] {
        (try? context.fetch(FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == roomUUID }))) ?? []
    }

    /// 同一个 uuid 两行(私有库镜像 + 共享库各落一行):留一行。
    private func removeChatDuplicates(_ roomUUID: UUID, context: ModelContext) {
        let rooms = (try? context.fetch(FetchDescriptor<ChatRoom>(
            predicate: #Predicate { $0.uuid == roomUUID }))) ?? []
        let extraMessages = SharedTripPlanner.duplicates(chatMessages(in: roomUUID, context: context), uuid: \.uuid)
        let extraRooms = Array(rooms.dropFirst())
        guard !(extraMessages.isEmpty && extraRooms.isEmpty) else { return }
        applying = true
        defer { applying = false }
        extraRooms.forEach(context.delete)
        extraMessages.forEach(context.delete)
        try? context.save()
    }

    // MARK: - 对账(本地 → 服务器)

    func scheduleReconcile() {
        guard !applying, !scheduled, privateEngine != nil else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            scheduled = false
            reconcile()
        }
    }

    func reconcile() {
        guard let context, let privateEngine, let sharedEngine, !applying else { return }
        var zones = SharedTripLedger.zones
        guard !zones.isEmpty else {
            pendingCounts = [:]
            return
        }
        for (key, zone) in zones {
            let engine = zone.role == .owner ? privateEngine : sharedEngine
            let zoneID = CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName)
            if zone.kind == .chat {
                guard let room = fetchRoom(zone.containerUUID, context: context) else {
                    // 本地没有这个房间了:只有账本里**见过**房间记录才算是被删掉的(在自己另一台
                    // 设备上销毁/退出,经私有库镜像同步过来)。刚登记、记录还没拉下来的 zone
                    // 本地自然也没有,那时删 zone 就把刚加入的房间退掉了。
                    if zone.records[zone.containerUUID] != nil {
                        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
                        zones[key] = nil
                    }
                    continue
                }
                removeChatDuplicates(zone.containerUUID, context: context)
                let plan = SharedChatPlanner.pushPlan(
                    room: SharedChatMapping.snapshot(of: room),
                    myMessages: chatMessages(in: zone.containerUUID, context: context)
                        .filter(\.fromMe).map(SharedChatMapping.snapshot(of:)),
                    ledger: zone.records)
                guard !plan.isEmpty else { continue }
                engine.state.add(pendingRecordZoneChanges:
                    plan.saves.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) })
                continue
            }
            if zone.kind == .assets {
                removeAssetDuplicates(zone.containerUUID, context: context)
                let plan = SharedTripPlanner.pushPlan(
                    local: assetSnapshots(zone.containerUUID, context: context), ledger: zone.records)
                guard !plan.isEmpty else { continue }
                engine.state.add(pendingRecordZoneChanges:
                    plan.saves.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
                    + plan.deletes.map { .deleteRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) })
                continue
            }
            guard let trip = fetchTrip(zone.tripUUID, context: context) else {
                // 旅行在本地删掉了:owner 删 zone(成员那边收到后各自留一份不共享的
                // 副本),成员删 shared database 里的 zone = 退出共享。
                engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
                zones[key] = nil
                continue
            }
            removeDuplicates(of: zone.tripUUID, context: context)
            let plan = SharedTripPlanner.pushPlan(local: localSnapshots(for: trip, context: context),
                                                  ledger: zone.records)
            guard !plan.isEmpty else { continue }
            let changes: [CKSyncEngine.PendingRecordZoneChange] =
                plan.saves.map { .saveRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
                + plan.deletes.map { .deleteRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)) }
            engine.state.add(pendingRecordZoneChanges: changes)
        }
        saveZones(zones)
        updatePendingCounts()
    }

    private func assetSnapshots(_ ledgerUUID: UUID, context: ModelContext) -> [SharedRecordSnapshot] {
        assetItems(in: ledgerUUID, context: context).filter(\.isAsset).map(SharedAssetMapping.snapshot(ofAsset:))
            + financeEntries(in: ledgerUUID, context: context).map(SharedAssetMapping.snapshot(of:))
    }

    /// 同旅行那条(`removeDuplicates`):同一个 uuid 两行留一行,多出来的不走
    /// `MemoryPipeline.delete`(会把共用的文件删掉)。
    private func removeAssetDuplicates(_ ledgerUUID: UUID, context: ModelContext) {
        let extraItems = SharedTripPlanner.duplicates(assetItems(in: ledgerUUID, context: context), uuid: \.uuid)
        let extraEntries = SharedTripPlanner.duplicates(financeEntries(in: ledgerUUID, context: context), uuid: \.uuid)
        guard !(extraItems.isEmpty && extraEntries.isEmpty) else { return }
        applying = true
        defer { applying = false }
        extraItems.forEach(context.delete)
        extraEntries.forEach(context.delete)
        try? context.save()
    }

    private func assetItems(in ledgerUUID: UUID, context: ModelContext) -> [MemoryItem] {
        let id: UUID? = ledgerUUID
        return (try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.assetLedgerUUID == id }))) ?? []
    }

    private func financeEntries(in ledgerUUID: UUID, context: ModelContext) -> [FinanceEntry] {
        let id: UUID? = ledgerUUID
        return (try? context.fetch(FetchDescriptor<FinanceEntry>(
            predicate: #Predicate { $0.ledgerUUID == id }))) ?? []
    }

    private func fetchFinance(_ uuid: UUID, context: ModelContext) -> FinanceEntry? {
        try? context.fetch(FetchDescriptor<FinanceEntry>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func localSnapshots(for trip: TravelTrip, context: ModelContext) -> [SharedRecordSnapshot] {
        var result = [SharedTripMapping.snapshot(of: trip)]
        result += entries(of: trip.uuid, context: context).map(SharedTripMapping.snapshot(of:))
        result += packingItems(of: trip.uuid, context: context).map(SharedTripMapping.snapshot(of:))
        return result
    }

    /// 同一个 uuid 两行(成员的两台设备各落了一行,再经私有库镜像汇到一起):
    /// 留一行。多出来的那行不走 `MemoryPipeline.delete`——两行指着同一个文件,
    /// 那样会把留下那行的文件也删了。
    private func removeDuplicates(of tripUUID: UUID, context: ModelContext) {
        let trips = (try? context.fetch(FetchDescriptor<TravelTrip>(
            predicate: #Predicate { $0.uuid == tripUUID }))) ?? []
        let extraEntries = SharedTripPlanner.duplicates(entries(of: tripUUID, context: context), uuid: \.uuid)
        let extraPacking = SharedTripPlanner.duplicates(packingItems(of: tripUUID, context: context), uuid: \.uuid)
        let extraTrips = Array(trips.dropFirst())
        guard !(extraEntries.isEmpty && extraPacking.isEmpty && extraTrips.isEmpty) else { return }
        applying = true
        defer { applying = false }
        extraTrips.forEach(context.delete)
        extraEntries.forEach(context.delete)
        extraPacking.forEach(context.delete)
        try? context.save()
    }

    private func updatePendingCounts() {
        var counts: [UUID: Int] = [:]
        for zone in SharedTripLedger.zones.values {
            let engine = zone.role == .owner ? privateEngine : sharedEngine
            let n = engine?.state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let id), .deleteRecord(let id):
                    return id.zoneID.zoneName == zone.zoneName
                @unknown default:
                    return false
                }
            }.count ?? 0
            if n > 0 { counts[zone.tripUUID] = n }
        }
        if counts != pendingCounts { pendingCounts = counts }
    }

    // MARK: - 查询

    private func fetchTrip(_ uuid: UUID, context: ModelContext) -> TravelTrip? {
        try? context.fetch(FetchDescriptor<TravelTrip>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    /// 挂在这趟旅行上的全部记忆条目(行程项 + 旅行文件)。
    private func entries(of tripUUID: UUID, context: ModelContext) -> [MemoryItem] {
        let id: UUID? = tripUUID
        return (try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.travelTripUUID == id }))) ?? []
    }

    private func packingItems(of tripUUID: UUID, context: ModelContext) -> [PackingItem] {
        (try? context.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate { $0.tripUUID == tripUUID }))) ?? []
    }

    private func fetchEntry(_ uuid: UUID, context: ModelContext) -> MemoryItem? {
        try? context.fetch(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func fetchPacking(_ uuid: UUID, context: ModelContext) -> PackingItem? {
        try? context.fetch(FetchDescriptor<PackingItem>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    private func engine(for role: SharedTripRole) -> CKSyncEngine? {
        role == .owner ? privateEngine : sharedEngine
    }

    private func zoneEntry(for zoneID: CKRecordZone.ID) -> SharedZoneLedger? {
        SharedTripLedger.zones[SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)]
    }

    // MARK: - 记录 ↔ CKRecord

    private func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let context, let zone = zoneEntry(for: recordID.zoneID),
              let uuid = UUID(uuidString: recordID.recordName) else { return nil }
        let snapshot: SharedRecordSnapshot
        var fileItem: MemoryItem?
        if zone.kind == .chat {
            if uuid == zone.containerUUID, let room = fetchRoom(uuid, context: context) {
                snapshot = SharedChatMapping.snapshot(of: room)
            } else if let message = fetchChatMessage(uuid, context: context),
                      message.roomUUID == zone.containerUUID {
                snapshot = SharedChatMapping.snapshot(of: message)
            } else {
                return nil
            }
        } else if zone.kind == .assets {
            if let item = fetchEntry(uuid, context: context), item.assetLedgerUUID == zone.containerUUID {
                snapshot = SharedAssetMapping.snapshot(ofAsset: item)
                fileItem = item
            } else if let entry = fetchFinance(uuid, context: context), entry.ledgerUUID == zone.containerUUID {
                snapshot = SharedAssetMapping.snapshot(of: entry)
            } else {
                return nil
            }
        } else if uuid == zone.tripUUID, let trip = fetchTrip(uuid, context: context) {
            snapshot = SharedTripMapping.snapshot(of: trip)
        } else if let item = fetchEntry(uuid, context: context), item.travelTripUUID == zone.tripUUID {
            snapshot = SharedTripMapping.snapshot(of: item)
            fileItem = item
        } else if let item = fetchPacking(uuid, context: context), item.tripUUID == zone.tripUUID {
            snapshot = SharedTripMapping.snapshot(of: item)
        } else {
            return nil  // 已经没了(或挪去了别的旅行),引擎会丢掉这条待存
        }
        let base = zone.records[uuid]
        let record = base?.systemFields.flatMap(Self.decodeSystemFields)
            ?? CKRecord(recordType: snapshot.type.rawValue, recordID: recordID)
        record["payload"] = SharedTripMapping.encode(snapshot.fields) as CKRecordValue?
        if let fileItem { attachAssets(of: fileItem, to: record, base: base?.fields) }
        return record
    }

    /// 文件和附件各一个 CKAsset。只在路径变了(或第一次上传)时带上——没动过的字段
    /// 保存时不发,服务器上原来那份留着,改个标题不用重传一遍 PDF。
    private func attachAssets(of item: MemoryItem, to record: CKRecord, base: SharedFields?) {
        let snapshot = SharedTripMapping.snapshot(of: item).fields
        if snapshot["relativeFilePath"] != base?["relativeFilePath"],
           let url = MemoryPipeline.fileURL(of: item), Self.fitsAssetLimit(url) {
            record["file"] = CKAsset(fileURL: url)
        }
        if snapshot["attachmentRelativePaths"] != base?["attachmentRelativePaths"] {
            for (index, relative) in item.attachmentRelativePaths.enumerated() {
                guard let url = AppGroup.containerURL?.appending(path: relative),
                      FileManager.default.fileExists(atPath: url.path),
                      Self.fitsAssetLimit(url) else { continue }
                record["attachment\(index)"] = CKAsset(fileURL: url)
            }
        }
    }

    private static func fitsAssetLimit(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size <= SharedTripMapping.maxAssetBytes
    }

    /// 收到的文件落回 App Group 里同一个相对路径(文件名本来就带 uuid,各设备一致)。
    private func saveAssets(of record: CKRecord, fields: SharedFields) {
        func copy(_ value: Any?, to relative: String?) {
            guard let asset = value as? CKAsset, let source = asset.fileURL,
                  let relative, let target = AppGroup.containerURL?.appending(path: relative) else { return }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
        if case .string(let path) = fields["relativeFilePath"] {
            copy(record["file"], to: path)
        }
        if case .strings(let paths) = fields["attachmentRelativePaths"] {
            for (index, path) in paths.enumerated() {
                copy(record["attachment\(index)"], to: path)
            }
        }
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: - 服务器 → 本地

    private func register(_ zoneID: CKRecordZone.ID, role: SharedTripRole) {
        guard let containerUUID = SharedZoneKind.containerUUID(fromZoneName: zoneID.zoneName) else { return }
        var zones = SharedTripLedger.zones
        let key = SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        guard zones[key] == nil else { return }
        zones[key] = SharedZoneLedger(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName,
                                      role: role, tripUUID: containerUUID)
        saveZones(zones)
    }

    /// zone 没了(owner 停止共享/删了旅行、自己退出了):本地留一份不共享的副本。
    private func zoneRemoved(_ zoneID: CKRecordZone.ID) {
        var zones = SharedTripLedger.zones
        let key = SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        guard let entry = zones[key] else { return }
        zones[key] = nil
        saveZones(zones)
        if entry.kind == .chat {
            // 聊天室没有"留一份副本":销毁就是全删(创建者销毁、自己退出、被移出都一样)。
            deleteLocalRoom(entry.containerUUID)
        } else if entry.kind == .assets {
            clearAssetMarkers(entry.containerUUID)
        } else if let context, let trip = fetchTrip(entry.tripUUID, context: context) {
            markUnshared(trip)
        }
    }

    private func markUnshared(_ trip: TravelTrip) {
        applying = true
        defer { applying = false }
        trip.shareRoleRaw = ""
        trip.shareZoneOwner = ""
        try? context?.save()
        pendingCounts[trip.uuid] = nil
    }

    private func applyIncoming(_ records: [CKRecord]) {
        guard let context, !records.isEmpty else { return }
        applying = true
        defer { applying = false }
        var zones = SharedTripLedger.zones
        var reindex: [MemoryItem] = []
        var financeChanged = false
        for record in records {
            let zoneID = record.recordID.zoneID
            let key = SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
            guard var zone = zones[key],
                  let uuid = UUID(uuidString: record.recordID.recordName),
                  let type = SharedRecordType(rawValue: record.recordType),
                  let payload = record["payload"] as? Data,
                  let server = SharedTripMapping.decode(payload) else { continue }
            let base = zone.records[uuid]?.fields
            let addedBy = addedByName(record, zone: zone)

            switch type {
            case .trip:
                let trip = fetchTrip(uuid, context: context)
                switch SharedTripPlanner.incoming(server: server, base: base,
                                                  local: trip.map { SharedTripMapping.snapshot(of: $0).fields }) {
                case .insert(let fields):
                    let new = TravelTrip(uuid: uuid)
                    SharedTripMapping.apply(fields, to: new)
                    new.shareRoleRaw = zone.role.rawValue
                    new.shareZoneOwner = zone.ownerName
                    context.insert(new)
                case .update(let fields):
                    if let trip {
                        SharedTripMapping.apply(fields, to: trip)
                        trip.shareRoleRaw = zone.role.rawValue
                        trip.shareZoneOwner = zone.ownerName
                    }
                case .skipDeletedLocally:
                    break
                }
            case .entry:
                let item = fetchEntry(uuid, context: context)
                switch SharedTripPlanner.incoming(server: server, base: base,
                                                  local: item.map { SharedTripMapping.snapshot(of: $0).fields }) {
                case .insert(let fields):
                    let new = MemoryItem(kind: .text)
                    new.uuid = uuid
                    SharedTripMapping.apply(fields, to: new)
                    new.travelTripUUID = zone.tripUUID
                    new.sharedAddedBy = addedBy
                    context.insert(new)
                    saveAssets(of: record, fields: fields)
                    reindex.append(new)
                case .update(let fields):
                    if let item {
                        let textChanged = item.sourceText != fields.stringValue("sourceText")
                        SharedTripMapping.apply(fields, to: item)
                        item.travelTripUUID = zone.tripUUID
                        if item.sharedAddedBy == nil { item.sharedAddedBy = addedBy }
                        saveAssets(of: record, fields: fields)
                        if textChanged { reindex.append(item) }
                    }
                case .skipDeletedLocally:
                    break
                }
            case .asset:
                let item = fetchEntry(uuid, context: context)
                switch SharedTripPlanner.incoming(server: server, base: base,
                                                  local: item.map { SharedAssetMapping.snapshot(ofAsset: $0).fields }) {
                case .insert(let fields):
                    let new = MemoryItem(kind: .text)
                    new.uuid = uuid
                    SharedAssetMapping.applyAsset(fields, to: new)
                    new.assetLedgerUUID = zone.containerUUID
                    new.sharedAddedBy = addedBy
                    context.insert(new)
                    saveAssets(of: record, fields: fields)
                    reindex.append(new)
                case .update(let fields):
                    if let item {
                        let textChanged = item.sourceText != fields.stringValue("sourceText")
                        SharedAssetMapping.applyAsset(fields, to: item)
                        item.assetLedgerUUID = zone.containerUUID
                        if item.sharedAddedBy == nil { item.sharedAddedBy = addedBy }
                        saveAssets(of: record, fields: fields)
                        if textChanged { reindex.append(item) }
                    }
                case .skipDeletedLocally:
                    break
                }
                financeChanged = true
            case .finance:
                let entry = fetchFinance(uuid, context: context)
                switch SharedTripPlanner.incoming(server: server, base: base,
                                                  local: entry.map { SharedAssetMapping.snapshot(of: $0).fields }) {
                case .insert(let fields):
                    let new = FinanceEntry(uuid: uuid, kind: .income, title: "")
                    SharedAssetMapping.apply(fields, to: new)
                    new.ledgerUUID = zone.containerUUID
                    new.sharedAddedBy = addedBy
                    context.insert(new)
                case .update(let fields):
                    if let entry {
                        SharedAssetMapping.apply(fields, to: entry)
                        entry.ledgerUUID = zone.containerUUID
                    }
                case .skipDeletedLocally:
                    break
                }
                financeChanged = true
            case .chatRoom:
                let room = fetchRoom(uuid, context: context) ?? {
                    let new = ChatRoom(uuid: uuid)
                    context.insert(new)
                    return new
                }()
                SharedChatMapping.apply(server, to: room)
                room.shareRoleRaw = zone.role.rawValue
                room.shareZoneOwner = zone.ownerName
            case .chatMessage:
                // 消息只追加:本地已经有了(自己发的,或经私有库镜像先到了)就不动。
                if fetchChatMessage(uuid, context: context) == nil {
                    let fromMe = record.creatorUserRecordID.map { $0.recordName == CKCurrentUserDefaultName } ?? false
                    let new = ChatRoomMessage(uuid: uuid, roomUUID: zone.containerUUID, content: "", fromMe: fromMe)
                    SharedChatMapping.apply(server, to: new)
                    if !fromMe {
                        new.senderName = addedBy ?? (new.senderHint.isEmpty
                            ? String(localized: "成员", bundle: .appLanguage()) : new.senderHint)
                    }
                    context.insert(new)
                    // 消息可能比房间记录先到(同一批里顺序不保证):先建个占位房间,
                    // 房间记录到了再写名字。
                    let room = fetchRoom(zone.containerUUID, context: context) ?? {
                        let placeholder = ChatRoom(uuid: zone.containerUUID)
                        placeholder.shareRoleRaw = zone.role.rawValue
                        placeholder.shareZoneOwner = zone.ownerName
                        context.insert(placeholder)
                        return placeholder
                    }()
                    if new.createdAt > room.lastMessageAt { room.lastMessageAt = new.createdAt }
                }
            case .packing:
                let item = fetchPacking(uuid, context: context)
                switch SharedTripPlanner.incoming(server: server, base: base,
                                                  local: item.map { SharedTripMapping.snapshot(of: $0).fields }) {
                case .insert(let fields):
                    let new = PackingItem(uuid: uuid, tripUUID: zone.tripUUID, title: "")
                    SharedTripMapping.apply(fields, to: new)
                    new.sharedAddedBy = addedBy
                    context.insert(new)
                case .update(let fields):
                    if let item { SharedTripMapping.apply(fields, to: item) }
                case .skipDeletedLocally:
                    break
                }
            }
            zone.records[uuid] = SharedLedgerRecord(type: type, fields: server,
                                                    systemFields: Self.encodeSystemFields(record))
            zones[key] = zone
        }
        saveZones(zones)
        try? context.save()
        // 别人加的信用卡:这台设备也各自生成还款提醒(防重复标记不同步,见 SharedAssetMapping)。
        if financeChanged { FinanceReminders.sync(context: context) }
        if !reindex.isEmpty {
            Task { await MemoryPipeline.reindexAll(reindex, context: context) }
        }
    }

    private func applyDeletions(_ deletions: [(CKRecord.ID, String)]) {
        guard let context, !deletions.isEmpty else { return }
        applying = true
        defer { applying = false }
        var zones = SharedTripLedger.zones
        for (recordID, recordType) in deletions {
            let key = SharedZoneLedger.key(zoneName: recordID.zoneID.zoneName,
                                           ownerName: recordID.zoneID.ownerName)
            guard var zone = zones[key], let uuid = UUID(uuidString: recordID.recordName) else { continue }
            switch SharedRecordType(rawValue: recordType) {
            case .entry:
                if let item = fetchEntry(uuid, context: context) { MemoryPipeline.delete(item, context: context) }
            case .packing:
                if let item = fetchPacking(uuid, context: context) { context.delete(item) }
            // 资产:别人的条目被移出共享 → 删掉本地副本;自己的(在自己另一台设备上
            // 移出了共享)→ 只摘标记。见 SharedAssetPlanner.onRemoteDeletion。
            case .asset:
                if let item = fetchEntry(uuid, context: context), item.assetLedgerUUID == zone.containerUUID {
                    switch SharedAssetPlanner.onRemoteDeletion(createdByMe: createdByMe(zone.records[uuid])) {
                    case .deleteLocal: MemoryPipeline.delete(item, context: context)
                    case .detachOnly: item.assetLedgerUUID = nil
                    }
                }
            case .finance:
                if let entry = fetchFinance(uuid, context: context), entry.ledgerUUID == zone.containerUUID {
                    switch SharedAssetPlanner.onRemoteDeletion(createdByMe: createdByMe(zone.records[uuid])) {
                    case .deleteLocal:
                        FinanceReminders.removeReminder(for: entry, context: context)
                        context.delete(entry)
                    case .detachOnly:
                        entry.ledgerUUID = nil
                    }
                }
            case .chatMessage:
                if let message = fetchChatMessage(uuid, context: context) { context.delete(message) }
            case .trip, .chatRoom, nil:
                break  // 旅行/聊天室本身的删除走 zone 删除(zoneRemoved)
            }
            zone.records[uuid] = nil
            zones[key] = zone
        }
        saveZones(zones)
        try? context.save()
    }

    /// 账本里那条记录是不是自己建的(按存下的系统字段里的创建者);没有系统字段时为 nil。
    private func createdByMe(_ record: SharedLedgerRecord?) -> Bool? {
        guard let data = record?.systemFields, let ck = Self.decodeSystemFields(data),
              let creator = ck.creatorUserRecordID?.recordName else { return nil }
        return creator == CKCurrentUserDefaultName
    }

    /// 「由 X 添加」:记录的创建者不是自己时,按共享成员表查名字。
    private func addedByName(_ record: CKRecord, zone: SharedZoneLedger) -> String? {
        guard let creator = record.creatorUserRecordID?.recordName,
              creator != CKCurrentUserDefaultName else { return nil }
        return participantNames[zone.key]?[creator]
    }

    private func loadParticipants(_ share: CKShare) async {
        let zoneID = share.recordID.zoneID
        let key = SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        var names: [String: String] = [:]
        for participant in share.participants {
            guard let id = participant.userIdentity.userRecordID?.recordName else { continue }
            let components = participant.userIdentity.nameComponents
            let name = components.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            } ?? participant.userIdentity.lookupInfo?.emailAddress
            if let name, !name.isEmpty {
                names[id] = name
                // 自己在成员表里的名字:聊天室里发消息时写进 payload 兜底(见 senderHint)。
                if participant == share.currentUserParticipant { Self.myDisplayName = name }
            }
        }
        participantNames[key] = names
    }

    /// 每个 zone 的成员表(拉数据前先取一次,「由 X 添加」才有名字可用)。
    private func loadParticipants(for zoneID: CKRecordZone.ID, database: CKDatabase) async {
        let key = SharedZoneLedger.key(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        guard participantNames[key] == nil else { return }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let share = try? await database.record(for: id) as? CKShare {
            await loadParticipants(share)
        }
    }

    // MARK: - 引擎事件

    fileprivate func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        let scope: SharedTripLedger.Scope = engine === sharedEngine ? .sharedDatabase : .privateDatabase
        switch event {
        case .stateUpdate(let update):
            SharedTripLedger.saveEngineState(try? JSONEncoder().encode(update.stateSerialization),
                                             for: scope)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                // 账号换了:账本、引擎状态都对不上了。本地共享旅行改回不共享的副本。
                resetAfterAccountChange()
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let changes):
            for modification in changes.modifications {
                register(modification.zoneID, role: scope == .sharedDatabase ? .participant : .owner)
            }
            for deletion in changes.deletions {
                zoneRemoved(deletion.zoneID)
            }
        case .willFetchRecordZoneChanges(let info):
            await loadParticipants(for: info.zoneID, database: engine.database)
        case .fetchedRecordZoneChanges(let changes):
            applyIncoming(changes.modifications.map(\.record))
            applyDeletions(changes.deletions.map { ($0.recordID, $0.recordType) })
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: engine)
        case .sentDatabaseChanges(let sent):
            // 建 zone / 删 zone 失败原来完全没人管,记录那边就会一直 zoneNotFound。
            for failure in sent.failedZoneSaves {
                noteThrottle(failure.error)
                if failure.error.retryAfterSeconds == nil { report(failure.error.localizedDescription) }
            }
            for (_, error) in sent.failedZoneDeletes where error.code != .zoneNotFound {
                noteThrottle(error)
                if error.retryAfterSeconds == nil { report(error.localizedDescription) }
            }
        case .didSendChanges, .didFetchChanges:
            updatePendingCounts()
        default:
            break
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var zones = SharedTripLedger.zones
        for record in sent.savedRecords {
            let key = SharedZoneLedger.key(zoneName: record.recordID.zoneID.zoneName,
                                           ownerName: record.recordID.zoneID.ownerName)
            guard var zone = zones[key], let uuid = UUID(uuidString: record.recordID.recordName),
                  let type = SharedRecordType(rawValue: record.recordType),
                  let payload = record["payload"] as? Data,
                  let fields = SharedTripMapping.decode(payload) else { continue }
            zone.records[uuid] = SharedLedgerRecord(type: type, fields: fields,
                                                    systemFields: Self.encodeSystemFields(record))
            zones[key] = zone
        }
        for recordID in sent.deletedRecordIDs {
            let key = SharedZoneLedger.key(zoneName: recordID.zoneID.zoneName,
                                           ownerName: recordID.zoneID.ownerName)
            guard let uuid = UUID(uuidString: recordID.recordName) else { continue }
            zones[key]?.records[uuid] = nil
        }
        saveZones(zones)

        var conflicts: [CKRecord] = []
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // 别人先存了:拿服务器那份和本地三方合并,合并结果留在本地,下一轮
                // 对账发现和账本(现在 = 服务器那份)不一样就再推。
                if let server = failure.error.serverRecord { conflicts.append(server) }
            case .zoneNotFound:
                // 重建 zone 再重存,**每条记录每次启动只补救一次**:原来无限次立刻
                // 重排,zone 建不起来时就是一个打满 CloudKit 的死循环(会被 503 限流)。
                if zoneEntry(for: recordID.zoneID)?.role == .owner {
                    guard retriedRecords.insert(recordID).inserted else {
                        report(failure.error.localizedDescription)
                        continue
                    }
                    if recreatedZones.insert(recordID.zoneID).inserted {
                        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
                    }
                    retry.append(.saveRecord(recordID))
                } else {
                    zoneRemoved(recordID.zoneID)
                }
            case .unknownItem:
                // 服务器上已经没有这条了:丢掉旧的系统字段,当新记录重存(同样只补救一次)。
                guard retriedRecords.insert(recordID).inserted else {
                    report(failure.error.localizedDescription)
                    continue
                }
                var zones = SharedTripLedger.zones
                let key = SharedZoneLedger.key(zoneName: recordID.zoneID.zoneName,
                                               ownerName: recordID.zoneID.ownerName)
                if let uuid = UUID(uuidString: recordID.recordName) {
                    zones[key]?.records[uuid]?.systemFields = nil
                    saveZones(zones)
                }
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                // 引擎自己会按服务器给的 retryAfter 退避重试,这里只记下限流截止时间。
                noteThrottle(failure.error)
            default:
                report(failure.error.localizedDescription)
            }
        }
        applyIncoming(conflicts)
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        if !conflicts.isEmpty { scheduleReconcile() }
        updatePendingCounts()
    }

    private func resetAfterAccountChange() {
        guard let context else { return }
        for zone in SharedTripLedger.zones.values {
            if zone.kind == .chat {
                // 换了账号就不再是那个房间的成员了;本地留着也发不出去,改回"未共享"。
                if let room = fetchRoom(zone.containerUUID, context: context) {
                    room.shareRoleRaw = ""
                    room.shareZoneOwner = ""
                }
            } else if zone.kind == .assets {
                clearAssetMarkers(zone.containerUUID)
            } else if let trip = fetchTrip(zone.tripUUID, context: context) {
                markUnshared(trip)
            }
        }
        SharedTripLedger.reset()
        refreshAssetShare([:])
        privateEngine = nil
        sharedEngine = nil
        isAvailable = false
        participantNames = [:]
        Task { await start() }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext,
                               engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await SharedTripSync.shared.buildRecord(for: recordID)
        }
    }
}

extension SharedTripSync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, engine: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(context, engine: syncEngine)
    }
}

private extension Dictionary where Key == String, Value == SharedFieldValue {
    func stringValue(_ key: String) -> String? {
        if case .string(let value) = self[key] { return value }
        return nil
    }
}
