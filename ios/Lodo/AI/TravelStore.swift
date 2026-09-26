import Foundation
import SwiftData
import CoreLocation
import LodoCore

/// 旅行的应用层操作:行程项的增删改查,以及给 AI 的行程摘要。
///
/// 行程项就是打了保留标签「旅行」的 `MemoryItem`(见 `TravelTrip` 的注释),所以
/// 这里落库的路子和 `MemoryPipeline.saveAsset`/`saveContact` 一样——字段已经
/// 结构化了,**不经 AI 整理**直接落成 ready,省一次网络请求、离线也能记;仍然跑
/// 分片+向量索引,所以"问 AI"能检索到行程里的内容。
@MainActor
enum TravelStore {

    // MARK: - 查询

    static func trips(in context: ModelContext) -> [TravelTrip] {
        let all = (try? context.fetch(FetchDescriptor<TravelTrip>())) ?? []
        return all.sorted { $0.startDate > $1.startDate }
    }

    /// 某次旅行的行程项(记忆条目本体)。
    static func items(for tripUUID: UUID, in context: ModelContext) -> [MemoryItem] {
        let all = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        return all.filter { $0.isTravel && $0.travelTripUUID == tripUUID }
    }

    /// 某次旅行的行程项值快照(喂给 TravelPlan 那套纯逻辑)。
    static func entries(for tripUUID: UUID, in context: ModelContext) -> [TravelEntry] {
        TravelPlan.sorted(items(for: tripUUID, in: context).compactMap(TravelEntry.init(from:)))
    }

    /// 同上,但吃调用方已经拿在手里的 @Query 结果,不再打一次 fetch
    /// (视图每帧都要重算,和 MemoryTags.entries 那个纯内存重载同一个理由)。
    static func entries(for tripUUID: UUID, from items: [MemoryItem]) -> [TravelEntry] {
        TravelPlan.sorted(items
            .filter { $0.isTravel && $0.travelTripUUID == tripUUID }
            .compactMap(TravelEntry.init(from:)))
    }

    // MARK: - 落库

    /// 新建一个行程项。字段已经结构化,不经 AI 整理直接落成 ready。
    @discardableResult
    static func create(
        tripUUID: UUID, kind: TravelItemKind, title: String, note: String = "",
        code: String? = nil, start: Date? = nil, end: Date? = nil,
        price: Double? = nil, currency: String? = nil,
        placeName: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        originName: String? = nil, originLatitude: Double? = nil, originLongitude: Double? = nil,
        flight: FlightDetails? = nil,
        context: ModelContext
    ) -> MemoryItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = MemoryItem(
            kind: .text, title: trimmed, summary: note,
            tags: [MemoryItem.travelTagName],
            sourceText: MemorySearch.truncate(searchText(
                title: trimmed, note: note, code: code,
                placeName: placeName, originName: originName, flight: flight)),
            status: .ready,
            travelTripUUID: tripUUID, travelKind: kind, travelStart: start, travelEnd: end,
            travelPrice: price, travelCurrency: currency,
            travelPlaceName: placeName, travelLatitude: latitude, travelLongitude: longitude,
            travelOriginName: originName, travelOriginLatitude: originLatitude,
            travelOriginLongitude: originLongitude, travelCode: code,
            travelFlightData: kind == .flight ? FlightDetails.encode(flight) : nil)
        context.insert(item)
        MemoryPipeline.finishStructuredSave(item, context: context)
        return item
    }

    /// 拖到另一天:日期换成目标那天,**几点几分不变**;有结束时间的(住宿退房)
    /// 整体平移同样的天数,时长不变。没有开始时间的(未排期)拖进某天就落在那天 9 点。
    static func move(_ item: MemoryItem, toDay day: Date, context: ModelContext,
                     calendar: Calendar = .current) {
        let target = calendar.startOfDay(for: day)
        if let start = item.travelStart {
            let shift = calendar.startOfDay(for: start).distance(to: target)
            guard shift != 0 else { return }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                               to: target).day ?? 0
            item.travelStart = calendar.date(byAdding: .day, value: days, to: start)
            if let end = item.travelEnd {
                item.travelEnd = calendar.date(byAdding: .day, value: days, to: end)
            }
        } else {
            item.travelStart = calendar.date(byAdding: .hour, value: 9, to: target)
        }
        MemoryPipeline.finishStructuredSave(item, context: context)
    }

    /// 编辑已有行程项(表单保存)。
    static func update(
        _ item: MemoryItem, kind: TravelItemKind, title: String, note: String,
        code: String?, start: Date?, end: Date?, price: Double?, currency: String?,
        placeName: String?, latitude: Double?, longitude: Double?,
        originName: String?, originLatitude: Double?, originLongitude: Double?,
        flight: FlightDetails?,
        context: ModelContext
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        item.title = trimmed
        item.summary = note
        item.travelKindRaw = kind.rawValue
        item.travelStart = start
        item.travelEnd = end
        item.travelPrice = price
        item.travelCurrency = currency
        item.travelPlaceName = placeName
        item.travelLatitude = latitude
        item.travelLongitude = longitude
        item.travelOriginName = originName
        item.travelOriginLatitude = originLatitude
        item.travelOriginLongitude = originLongitude
        item.travelCode = code
        item.travelFlightData = kind == .flight ? FlightDetails.encode(flight) : nil
        item.sourceText = MemorySearch.truncate(searchText(
            title: trimmed, note: note, code: code,
            placeName: placeName, originName: originName, flight: flight))
        MemoryPipeline.finishStructuredSave(item, context: context)
    }

    /// AI 从订单里解析出来、用户确认过的一条,落成行程项。
    @discardableResult
    static func create(
        from parsed: ParsedTravelItem, tripUUID: UUID, context: ModelContext
    ) -> MemoryItem? {
        create(tripUUID: tripUUID, kind: parsed.kind, title: parsed.title, note: parsed.note,
               code: parsed.code, start: parsed.start, end: parsed.end,
               price: parsed.price, currency: parsed.currency,
               placeName: parsed.placeName, originName: parsed.originName,
               flight: stamped(parsed.flight), context: context)
    }

    /// 这次导入的航班在行程里已经有了(同一航班号):返回那一条,导入时合并进去而不是
    /// 再建一条。航班号相同但日期明显不同的(往返同号、第二天同一班)不算同一条。
    static func existingFlight(
        for parsed: ParsedTravelItem, in items: [MemoryItem]
    ) -> MemoryItem? {
        guard parsed.kind == .flight else { return nil }
        let number = FlightDetails.normalizedNumber(parsed.code)
        guard !number.isEmpty else { return nil }
        return items.first { item in
            guard item.isTravel, item.travelKind == .flight,
                  FlightDetails.normalizedNumber(item.travelCode) == number else { return false }
            guard let a = parsed.start, let b = item.travelStart else { return true }
            return abs(a.timeIntervalSince(b)) < 20 * 3600
        }
    }

    /// 把新导入的一条合并进已有航班——这就是"航班动态更新":再导入一张登机牌或
    /// 航班动态截图,补充信息里有的字段覆盖、没有的保留;基本信息(时间/地点/价格)
    /// 只在原来空着时才填,不拿截图 OCR 的结果去覆盖用户已经确认过的内容。
    static func merge(_ parsed: ParsedTravelItem, into item: MemoryItem, context: ModelContext) {
        if item.travelStart == nil { item.travelStart = parsed.start }
        if item.travelEnd == nil { item.travelEnd = parsed.end }
        if (item.travelPlaceName ?? "").isEmpty { item.travelPlaceName = parsed.placeName }
        if (item.travelOriginName ?? "").isEmpty { item.travelOriginName = parsed.originName }
        if item.travelPrice == nil, let price = parsed.price {
            item.travelPrice = price
            item.travelCurrency = parsed.currency
        }
        if let newer = stamped(parsed.flight) {
            let old = FlightDetails.decode(item.travelFlightData) ?? FlightDetails()
            item.travelFlightData = FlightDetails.encode(old.merged(with: newer))
        }
        let flight = FlightDetails.decode(item.travelFlightData)
        item.sourceText = MemorySearch.truncate(searchText(
            title: item.title, note: item.summary, code: item.travelCode,
            placeName: item.travelPlaceName, originName: item.travelOriginName, flight: flight))
        MemoryPipeline.finishStructuredSave(item, context: context)
    }

    /// 给这次导入的补充信息打上"什么时候更新的"。
    private static func stamped(_ flight: FlightDetails?) -> FlightDetails? {
        guard var flight, !flight.isEmpty else { return nil }
        flight.updatedAt = Date()
        return flight
    }

    /// 删掉一次旅行,连同它下面的行程项(行程项是记忆条目,走 MemoryPipeline.delete
    /// 才能把附件和向量分片一起清掉)。
    static func deleteTrip(_ trip: TravelTrip, context: ModelContext) {
        for item in items(for: trip.uuid, in: context) {
            MemoryPipeline.delete(item, context: context)
        }
        context.delete(trip)
        try? context.save()
    }

    /// 把行程项从这次旅行里移除。默认连记忆条目一起删——它本来就是为这趟行程建的;
    /// `keepMemory` 时只摘掉旅行标签和归属,条目留在记忆库里。
    static func remove(_ item: MemoryItem, keepMemory: Bool = false, context: ModelContext) {
        guard keepMemory else {
            MemoryPipeline.delete(item, context: context)
            return
        }
        item.tags.removeAll { $0 == MemoryItem.travelTagName }
        item.travelTripUUID = nil
        item.travelKindRaw = nil
        try? context.save()
    }

    // MARK: - AI 规划

    /// 把一份 AI 规划(`plan_trip`)写进旅行,返回写入状态已回填的规划(调用方把它
    /// 存回聊天消息)。旅行名和已有某次旅行**完全一致**(忽略首尾空白与大小写)时写进
    /// 那次,否则按规划的名字和日期新建一次——不做模糊匹配:"东京"和"东京四日"
    /// 可能真的是两趟,写错了比多建一趟麻烦得多。已有旅行的日期不跟着规划改,
    /// 落在区间外的安排按天视图会单独列出来(`TravelPlan.outOfRange`)。
    static func applyPlan(_ plan: TripPlanProposal, context: ModelContext) -> TripPlanProposal {
        let name = plan.tripTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = trips(in: context).first {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        }
        let trip: TravelTrip
        if let existing {
            trip = existing
        } else {
            trip = TravelTrip(title: name, startDate: plan.startDate, endDate: plan.endDate,
                              notes: plan.summary)
            context.insert(trip)
        }
        // 城市/国家只在空着时补(用户自己填过的不覆盖)。**国家不是可有可无的展示字段**:
        // 地图按地名找坐标时靠它挡掉搜岔的结果,空着的话「清水寺」会落到国内的同名
        // 地方去(见 PlaceGeocoder 文件头)。
        if trip.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let city = plan.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            trip.city = city
        }
        if trip.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let country = plan.country?.trimmingCharacters(in: .whitespacesAndNewlines),
           !country.isEmpty {
            trip.country = country
        }
        var created: [UUID] = []
        for item in plan.items {
            if let saved = create(
                tripUUID: trip.uuid, kind: item.kind, title: item.title, note: item.note,
                start: item.start, end: item.end, price: item.price, currency: item.currency,
                placeName: item.placeName, context: context) {
                created.append(saved.uuid)
            }
        }
        try? context.save()
        var result = plan
        result.appliedTripUUID = trip.uuid
        result.appliedItemUUIDs = created
        result.createdTrip = existing == nil
        result.reverted = false
        return result
    }

    /// 撤销一次规划写入:删掉那次写入新建的行程项;旅行本身是那次新建的、并且
    /// 删完之后已经空了,就连旅行一起删。用户在这期间往里手动加过东西的话旅行
    /// 保留——那些不是规划写进去的,不能连坐。
    static func revertPlan(_ plan: TripPlanProposal, context: ModelContext) -> TripPlanProposal {
        guard let tripUUID = plan.appliedTripUUID else { return plan }
        let uuids = Set(plan.appliedItemUUIDs ?? [])
        for item in items(for: tripUUID, in: context) where uuids.contains(item.uuid) {
            MemoryPipeline.delete(item, context: context)
        }
        if plan.createdTrip == true, items(for: tripUUID, in: context).isEmpty,
           let trip = trips(in: context).first(where: { $0.uuid == tripUUID }) {
            context.delete(trip)
        }
        try? context.save()
        var result = plan
        result.reverted = true
        return result
    }

    // MARK: - 地图坐标补全

    /// 打开旅行详情时把坐标过一遍:先把**存错国家**的清掉(`pruneMisplacedCoordinates`),
    /// 再给缺坐标的补上(`fillMissingCoordinates`)。顺序要紧——清掉的那几项正好
    /// 在同一轮里重新查一次,而且锚点只会从"已经验过"的坐标里取。
    static func refreshCoordinates(for trip: TravelTrip, context: ModelContext) async {
        await pruneMisplacedCoordinates(for: trip, context: context)
        await fillMissingCoordinates(for: trip, context: context)
    }

    /// 把落在别的国家的坐标清掉。
    ///
    /// 为什么要有这一步:`MKLocalSearch` 在国内网络上只给中国大陆数据(详见
    /// `PlaceGeocoder` 文件头),所以**库里已经存下了一批错坐标**——日本的行程项
    /// 指着辽宁、浙江的同名店铺。光修搜索那一侧救不了这些:它们有坐标,
    /// `fillMissingCoordinates` 会直接跳过,地图上就一直画在中国。
    ///
    /// 判据是反查:反查得到国家、并且和这趟旅行的国家对不上 → 清掉,让它在同一轮里
    /// 按正确的判据重查一次。**反查失败一律不动**——在只有中国数据的环境里,反查
    /// 日本坐标本身就报错,那恰恰是坐标正确的情形。
    /// 认不出旅行国家时整步跳过(没有判据,不能凭猜清用户的数据)。
    ///
    /// **交通类(航班/火车/客车)一概不验**:一趟日本旅行的回程航班落在北京,
    /// 起降点本来就分处两国,拿旅行的国家去卡会把真坐标清掉;而它们的坐标来自
    /// 订单解析和表单(机场、车站),不是地名搜索猜的,本来也不会搜岔。
    static func pruneMisplacedCoordinates(
        for trip: TravelTrip, context: ModelContext, limit: Int = geocodeBudget
    ) async {
        guard let region = expectedRegion(for: trip) else { return }
        let pending = items(for: trip.uuid, in: context).filter {
            $0.travelLatitude != nil && $0.travelLongitude != nil
                && $0.travelKind?.isTransport != true
                && !verifiedCoordinates.contains($0.uuid)
        }
        guard !pending.isEmpty else { return }
        var cleared = false
        for item in pending.prefix(limit) {
            guard let lat = item.travelLatitude, let lon = item.travelLongitude else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            guard let actual = await PlaceGeocoder.regionCode(at: coordinate) else { continue }
            if PlaceRegion.matches(region, actual) {
                // 验过就记下来,同一台 app 里不再反查它(同 PlaceGeocoder.missed 的定位:
                // 内存级、不落盘,重开 app 会再验一遍)。
                verifiedCoordinates.insert(item.uuid)
            } else {
                item.travelLatitude = nil
                item.travelLongitude = nil
                cleared = true
            }
        }
        if cleared { try? context.save() }
    }

    /// 这一轮验过、确认在目标国家里的行程项。
    private static var verifiedCoordinates: Set<UUID> = []

    /// 把"有地名、没坐标"的行程项补上坐标,让它们能画到地图上。
    ///
    /// 坐标原本只有一条来路:用户在表单里点「搜索」选点(`PlaceSearchView`)。
    /// 手打的地名、AI 规划/调整生成的安排都没有坐标,地图那一页于是常年是空的。
    /// 这里在打开旅行详情时补一遍:按地名(带上旅行的城市/国家消歧)查一次
    /// `MKLocalSearch`,**查得到就记下来,查不到就留空**——留空的项照旧不上地图,
    /// 不编一个大概的位置糊弄(画错位置比不画更糟)。
    ///
    /// 航班不在此列:它的起降点是机场,名字来自订单解析,不拿地名搜索去猜。
    /// 一次最多补 `geocodeBudget` 条,逐条串行——`MKLocalSearch` 有限流,
    /// 并发打一堆只会集体拿到 throttled。
    static func fillMissingCoordinates(
        for trip: TravelTrip, context: ModelContext, limit: Int = geocodeBudget
    ) async {
        let all = items(for: trip.uuid, in: context)
        let pending = all.filter { item in
            item.travelLatitude == nil && item.travelLongitude == nil
                && item.travelKind != .flight && !geocodeQuery(for: item).isEmpty
        }
        guard !pending.isEmpty else { return }
        let hint = geocodeHint(for: trip)
        // 这趟旅行该在哪个国家。有它就只认那个国家的结果(见 PlaceGeocoder 文件头);
        // 认不出来(只填了城市名、旅行名里也看不出国家)时退回按锚点距离兜底。
        let region = expectedRegion(for: trip)
        // 先定一个锚点:这趟旅行大致在地球上的哪儿。有已经带坐标的行程项就用它
        // (航班除外——起降机场分处两地,拿它当锚点会把整趟偏到出发地去),
        // 否则按城市名单独搜一次。
        var anchor = all.first { $0.travelKind != .flight && $0.travelLatitude != nil }
            .flatMap { item in item.travelLatitude.flatMap { lat in
                item.travelLongitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
            } }
        if region == nil {
            // **认不出国家时,判据只能是一个验过的城市锚点**。这里不敢用现有行程项的
            // 坐标:没有国家判据的旅行正是当初最容易搜岔的那批,拿它自己存下的错坐标
            // 当锚点只会把错误坐实。验不出城市就整步跳过——不画点,也不乱画。
            anchor = await PlaceGeocoder.verifiedAnchor(city: anchorCity(for: trip), hint: hint)
            guard anchor != nil else { return }
        } else if anchor == nil, let hint {
            anchor = await PlaceGeocoder.coordinate(for: hint, region: region)
        }
        var filled = false
        for item in pending.prefix(limit) {
            guard let coordinate = await PlaceGeocoder.coordinate(
                for: geocodeQuery(for: item), hint: hint, anchor: anchor, region: region)
            else { continue }
            item.travelLatitude = coordinate.latitude
            item.travelLongitude = coordinate.longitude
            // 地名原来空着(用标题搜到的)时顺手补上,详情页那行才显示得出地点。
            if (item.travelPlaceName ?? "").isEmpty { item.travelPlaceName = item.title }
            anchor = anchor ?? coordinate
            filled = true
        }
        if filled { try? context.save() }
    }

    /// 消歧用的城市/国家。`TravelTrip.locationText` 是给人看的("东京 · 日本"),
    /// 那个中点拼进搜索词只会添乱,这里按空格拼。
    ///
    /// 城市/国家都空着时退回旅行名("东京四日"这类名字里通常就带着目的地)——
    /// AI 规划出来的旅行只有名字没有城市字段,那种情况正是最需要消歧的:整趟的
    /// 行程项一个坐标都没有,没有任何锚点可依。
    /// 这趟旅行的预期国家/地区(ISO 码)。按"国家字段 → 城市字段 → 旅行名"的顺序找
    /// 第一个认得出的(城市名里也常带国家,如"东京 · 日本";AI 规划出来的旅行往往
    /// 只有名字,而「日本关西七日游」这种名字里就写着)。一个都认不出时返回 nil,
    /// 调用方退回别的判据——**不猜**。
    static func expectedRegion(for trip: TravelTrip) -> String? {
        PlaceRegion.isoCode(in: [trip.country, trip.city, trip.title])
    }

    static func geocodeHint(for trip: TravelTrip) -> String? {
        let parts = [trip.city, trip.country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        let title = trip.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 验锚点时拿去搜的城市名:优先城市字段,空着就用旅行名(「东京四日」这种名字
    /// 里通常带着目的地;验不过就当作没有锚点,不会因此画错点)。
    private static func anchorCity(for trip: TravelTrip) -> String {
        let city = trip.city.trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? trip.title.trimmingCharacters(in: .whitespacesAndNewlines) : city
    }

    /// 一次补全最多查几条。够覆盖一趟旅行的常规条数,又不至于一打开详情页就把
    /// `MKLocalSearch` 打到限流。
    static let geocodeBudget = 25

    /// 拿去搜的词:优先填过的地点名,没填就用标题("清水寺"这种本身就是地名)。
    private static func geocodeQuery(for item: MemoryItem) -> String {
        let place = (item.travelPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return place.isEmpty ? item.title.trimmingCharacters(in: .whitespacesAndNewlines) : place
    }

    // MARK: - AI 调整

    /// 执行一次 `edit_trip`,返回改动记录(结果卡片展示 + 撤销用)。找不到旅行时返回 nil。
    ///
    /// 是哪次旅行:删/改引用的 id 能在库里定位到行程项时以它为准(模型抄错旅行名也
    /// 不会改错地方),否则按旅行名挑(和 read_trip 同一个 `pickTrip`)。**不属于这次
    /// 旅行的 id 一律不动**。
    ///
    /// 两类行程项不删不改,记进 skipped 如实报回去:① 航班——航班号时刻不是 AI 能
    /// 决定的;② 带附件的(订单确认单等)——删除会连文件一起清掉,撤销恢复不了文件。
    static func applyEdit(_ edit: TripEdit, context: ModelContext) -> TripEditRecord? {
        let allTravel = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []).filter(\.isTravel)
        let referencedTrip = edit.referencedIDs.lazy
            .compactMap { id in allTravel.first { $0.uuid == id }?.travelTripUUID }
            .first
        let trip = referencedTrip.flatMap { uuid in trips(in: context).first { $0.uuid == uuid } }
            ?? pickTrip(name: edit.tripTitle, in: context)
        guard let trip else { return nil }
        let tripItems = allTravel.filter { $0.travelTripUUID == trip.uuid }
        var record = TripEditRecord(tripUUID: trip.uuid, tripTitle: trip.title, summary: edit.summary)

        func protectedReason(_ item: MemoryItem) -> String? {
            if item.travelKind == .flight { return "\(item.title)(航班)" }
            if item.relativeFilePath != nil || !item.attachmentRelativePaths.isEmpty {
                return "\(item.title)(带附件)"
            }
            return nil
        }

        for id in edit.removeIDs {
            guard let item = tripItems.first(where: { $0.uuid == id }) else {
                record.skipped.append("一项找不到的行程")
                continue
            }
            if let reason = protectedReason(item) {
                record.skipped.append(reason)
                continue
            }
            record.removed.append(item.backup)
            MemoryPipeline.delete(item, context: context)
        }

        for change in edit.updates {
            guard let item = tripItems.first(where: { $0.uuid == change.id }) else {
                record.skipped.append("一项找不到的行程")
                continue
            }
            // 带附件的可以改时间/名称(不碰文件),只有航班不让改。
            if item.travelKind == .flight {
                record.skipped.append("\(item.title)(航班)")
                continue
            }
            record.updatedBefore.append(item.backup)
            let placeChanged = change.placeName != nil && change.placeName != item.travelPlaceName
            let newStart = change.start ?? item.travelStart
            // 只挪了开始时间没给结束时间:保持原来的时长,不然会出现"结束早于开始"。
            var newEnd = change.end ?? item.travelEnd
            if change.start != nil, change.end == nil,
               let oldStart = item.travelStart, let oldEnd = item.travelEnd, let newStart {
                newEnd = newStart.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
            }
            update(
                item, kind: item.travelKind ?? .place, title: change.title ?? item.title,
                note: change.note ?? item.summary, code: item.travelCode,
                start: newStart, end: newEnd,
                price: item.travelPrice, currency: item.travelCurrency,
                placeName: change.placeName ?? item.travelPlaceName,
                // 地点换了,原来的坐标就不对了——宁可不上地图也不能画错位置。
                latitude: placeChanged ? nil : item.travelLatitude,
                longitude: placeChanged ? nil : item.travelLongitude,
                originName: item.travelOriginName, originLatitude: item.travelOriginLatitude,
                originLongitude: item.travelOriginLongitude, flight: nil, context: context)
            record.updatedAfter.append(TripEditLine(
                id: item.uuid, kind: item.travelKind ?? .place, title: item.title,
                start: item.travelStart))
        }

        for addition in edit.additions {
            if let saved = create(
                tripUUID: trip.uuid, kind: addition.kind, title: addition.title,
                note: addition.note, start: addition.start, end: addition.end,
                price: addition.price, currency: addition.currency,
                placeName: addition.placeName, context: context) {
                record.added.append(TripEditLine(
                    id: saved.uuid, kind: addition.kind, title: saved.title, start: saved.travelStart))
            }
        }
        try? context.save()
        return record
    }

    /// 撤销一次调整:新增的删掉,删掉的按原 uuid 写回,改过的改回原样。
    /// 撤销期间用户自己又删了某条改过的项,那条就不再凭空复活(只改回存在的)。
    static func revertEdit(_ record: TripEditRecord, context: ModelContext) -> TripEditRecord {
        let all = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let addedIDs = Set(record.added.map(\.id))
        for item in all where addedIDs.contains(item.uuid) {
            MemoryPipeline.delete(item, context: context)
        }
        for backup in record.removed where !all.contains(where: { $0.uuid == backup.uuid }) {
            let item = MemoryItem(kind: .text)
            backup.apply(to: item)
            context.insert(item)
            MemoryPipeline.finishStructuredSave(item, context: context)
        }
        for backup in record.updatedBefore {
            guard let item = all.first(where: { $0.uuid == backup.uuid }) else { continue }
            backup.apply(to: item)
            MemoryPipeline.finishStructuredSave(item, context: context)
        }
        try? context.save()
        var result = record
        result.reverted = true
        return result
    }

    // MARK: - 给 AI

    /// `read_trip` 工具的返回。name 为空时挑"正在进行的那次,否则最近一次"。
    /// 一条旅行都没有时返回 nil,由调用方给"还没记过旅行"的说法。
    /// includeIDs:每项带上 id,`edit_trip` 要引用(AI 助手的 read_trip 恒开)。
    static func promptSummary(
        name: String, includeIDs: Bool = false, in context: ModelContext
    ) -> String? {
        guard let trip = pickTrip(name: name, in: context) else { return nil }
        return TravelPlan.promptSummary(
            tripTitle: trip.title, days: trip.days,
            entries: entries(for: trip.uuid, in: context), includeIDs: includeIDs)
    }

    /// 按名字挑一次旅行:名字包含匹配;名字为空或没匹配上时挑"正在进行的那次,
    /// 否则最近要出发的,再否则最近一次"。read_trip 和 edit_trip 共用这一份,
    /// 保证模型读到的和改的是同一趟。
    static func pickTrip(name: String, in context: ModelContext) -> TravelTrip? {
        let all = trips(in: context)
        guard !all.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let matched = all.first(where: { $0.title.localizedStandardContains(trimmed) }) {
            return matched
        }
        if let ongoing = all.first(where: { $0.isOngoing() }) { return ongoing }
        // trips 是按出发日倒序的,最后一条 upcoming 就是最近要出发的那次。
        if let upcoming = all.filter({ $0.isUpcoming() }).last { return upcoming }
        return all[0]
    }

    /// 行程项落进记忆库时可被搜索到的正文(地名/航班号都该能搜出来)。
    private static func searchText(
        title: String, note: String, code: String?, placeName: String?, originName: String?,
        flight: FlightDetails? = nil
    ) -> String {
        // 航司、座位、机型也收进去,"问 AI 我坐几排"才搜得到这条。
        let seat: String = flight?.seat.map { "座位 \($0)" } ?? ""
        let parts: [String] = [title, note, code ?? "", placeName ?? "", originName ?? "",
                               flight?.airline ?? "", seat, flight?.aircraft ?? ""]
        return parts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
