import Foundation
import SwiftData
import CoreLocation
import OSLog
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
    /// 某次旅行的**行程项**(有类型的:交通/住宿/地点)。旅行文件(`files`)虽然也挂着
    /// 这次旅行,但没有类型,不在这里——查坐标、撤销规划、导入去重这些路径只该看行程项,
    /// 把一份 PDF 当地点拿去查坐标就闹笑话了。
    static func items(for tripUUID: UUID, in context: ModelContext) -> [MemoryItem] {
        let all = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        return all.filter { $0.isTravel && $0.travelTripUUID == tripUUID && $0.travelKind != nil }
    }

    // MARK: - 旅行文件

    /// 旅行详情「文件」页:这次旅行相关的资料——专门挂到这次旅行上的记忆条目
    /// (机票行程单、签证、保险、攻略、截图……,没有行程类型),加上带着附件的行程项
    /// (导入订单时存下的确认单)。**只看这一次旅行**。新的在前。
    static func files(for tripUUID: UUID, from items: [MemoryItem]) -> [MemoryItem] {
        items.filter { item in
            guard item.travelTripUUID == tripUUID else { return false }
            return item.travelKind == nil
                || item.relativeFilePath != nil || !item.attachmentRelativePaths.isEmpty
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// 把一份本地文件收进这次旅行:落成一条记忆(照常 AI 整理、能被搜到),挂上
    /// 这次旅行和「旅行」标签,没有行程类型。
    @discardableResult
    static func attachFile(_ url: URL, to trip: TravelTrip, context: ModelContext) -> MemoryItem? {
        MemoryPipeline.saveFile(url, context: context, extraTags: [MemoryItem.travelTagName]) {
            $0.travelTripUUID = trip.uuid
        }
    }

    @discardableResult
    static func attachImage(_ data: Data, to trip: TravelTrip, context: ModelContext) -> MemoryItem? {
        MemoryPipeline.saveImageData(data, context: context, extraTags: [MemoryItem.travelTagName]) {
            $0.travelTripUUID = trip.uuid
        }
    }

    /// 把记忆库里已有的条目挂到这次旅行上(行程项不在此列,它们本来就属于某次旅行)。
    static func attachMemories(_ items: [MemoryItem], to trip: TravelTrip, context: ModelContext) {
        for item in items where item.travelKind == nil {
            item.travelTripUUID = trip.uuid
            if !item.tags.contains(MemoryItem.travelTagName) { item.tags.append(MemoryItem.travelTagName) }
        }
        try? context.save()
    }

    /// 从这次旅行里摘下一份文件,条目本身留在记忆库里。行程项不走这里(它们用 `remove`)。
    static func detachFile(_ item: MemoryItem, context: ModelContext) {
        guard item.travelKind == nil else { return }
        item.travelTripUUID = nil
        item.tags.removeAll { $0 == MemoryItem.travelTagName }
        try? context.save()
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
            travelFlightData: kind.isTransport ? FlightDetails.encode(flight) : nil)
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
        item.travelFlightData = kind.isTransport ? FlightDetails.encode(flight) : nil
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
        // 旅行文件是用户自己的资料(签证、保险单……),旅行删了它们照样该留在记忆库里:
        // 只摘下来,不删。
        let all = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for file in all where file.travelTripUUID == trip.uuid && file.travelKind == nil {
            detachFile(file, context: context)
        }
        // 用品清单只属于这一趟,跟着删。
        let tripUUID = trip.uuid
        let packing = (try? context.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate { $0.tripUUID == tripUUID }))) ?? []
        packing.forEach(context.delete)
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
        let regions = expectedRegions(for: trip)
        guard !regions.isEmpty else { return }
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
            // 多目的地(北海道 + 上海)时落在其中任何一个国家都算对。
            if regions.contains(where: { PlaceRegion.matches($0, actual) }) {
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

    /// 一轮地名查询的判据:这趟旅行在哪个国家、大致在哪儿(锚点)、消歧用的城市词。
    struct GeocodeContext {
        let region: String?
        var anchor: CLLocationCoordinate2D?
        let hint: String?
        /// 多目的地时这份判据对应哪个目的地(按行程项文字点名排序用);单目的地为 nil。
        var destination: TripDestination? = nil
    }

    /// 每个目的地一份判据。只有一个(或一个都没填)目的地时就是 `geocodeContext`
    /// 那一份,行为和原来一样;多个目的地(「北海道 · 日本」+「上海 · 中国」)时逐个
    /// 定国家和城市锚点,认不出也验不出城市的那个目的地跳过。
    ///
    /// 多目的地时不拿 `existingAnchor`:已有行程项的坐标属于哪个目的地说不清,
    /// 挂错了会让另一个目的地的地点挑成离错城市最近的同名店。
    static func geocodeContexts(for trip: TravelTrip,
                                existingAnchor: CLLocationCoordinate2D? = nil) async -> [GeocodeContext] {
        let destinations = trip.destinations
        guard destinations.count > 1 else {
            return await geocodeContext(for: trip, existingAnchor: existingAnchor).map { [$0] } ?? []
        }
        var contexts: [GeocodeContext] = []
        for destination in destinations {
            let cities = TravelDestination.cityCandidates(city: destination.city, title: "")
            if let region = destination.regionCode {
                let anchor = await PlaceGeocoder.verifiedAnchor(cities: cities, region: region)?.coordinate
                contexts.append(GeocodeContext(region: region, anchor: anchor,
                                               hint: destination.searchHint, destination: destination))
            } else if let verified = await PlaceGeocoder.verifiedAnchor(cities: cities) {
                contexts.append(GeocodeContext(region: verified.region, anchor: verified.coordinate,
                                               hint: destination.searchHint, destination: destination))
            }
        }
        return contexts
    }

    /// 定这一轮的判据。
    /// - 认得出国家(`expectedRegion`):锚点优先用调用方给的(已有行程项的坐标),
    ///   没有就按候选城市名验一个——原来拿「东京 日本」这串去查,苹果只给中国数据、
    ///   OSM 又过不了名字校验,锚点永远是 nil,同名地点只能听天由命。
    /// - 认不出国家(老旅行、AI 规划的旅行常常只有「东京四日」这么个名字):按候选城市名
    ///   (`TravelDestination.cityCandidates`,「东京四日」→「东京」)验一个城市锚点,
    ///   **国家就用锚点所在的国家**。原来拿整个旅行名去验,一条都验不出来,整轮直接跳过,
    ///   「刷新地点位置」点了地图纹丝不动。推出来的国家只用于这一轮,**不写回
    ///   `trip.country`**(那是用户手填、纯展示的字段)。
    /// 验不出城市时返回 nil——没有判据,宁可不画点。
    static func geocodeContext(for trip: TravelTrip,
                               existingAnchor: CLLocationCoordinate2D? = nil) async -> GeocodeContext? {
        let hint = geocodeHint(for: trip)
        let cities = TravelDestination.cityCandidates(city: trip.city, title: trip.title)
        if let region = expectedRegion(for: trip) {
            var anchor = existingAnchor
            if anchor == nil {
                anchor = await PlaceGeocoder.verifiedAnchor(cities: cities, region: region)?.coordinate
            }
            return GeocodeContext(region: region, anchor: anchor, hint: hint)
        }
        guard let verified = await PlaceGeocoder.verifiedAnchor(cities: cities) else { return nil }
        return GeocodeContext(region: verified.region, anchor: verified.coordinate, hint: hint)
    }

    /// 「刷新地点位置」的结果,分开数才看得出发生了什么:位置真的变了几个、
    /// 查到了但和原来一样的几个、没查到的几个。
    struct RelocateResult {
        var moved = 0
        var unchanged = 0
        var missed = 0
        /// 其中有几个位置是 AI 从 OpenStreetMap 候选里挑的(见 `calibratedLookUp`)。
        var aiPicked = 0
        /// 认不出这趟旅行在哪个城市,一个都没查。
        var destinationUnknown = false
        var total: Int { moved + unchanged + missed }
    }

    /// 详情页右上角「刷新地点位置」:把这次旅行里**所有**非交通类行程项按地名重新
    /// 查一遍坐标(打开详情页时那一遍只补缺的、清错国家的,已经有坐标的不再动;
    /// 地点改名、当初搜到的是同名的另一家时,只能靠这里手动重来)。
    ///
    /// 查到了就覆盖旧坐标,**查不到就留着旧的**——宁可停在原来的位置,也不把一个
    /// 好好的点清掉。判据见 `geocodeContext`,上一轮记下的"查不到"和"已验证"一并清掉重来。
    /// 交通类不查:起降点、车站来自订单和表单,不拿地名搜索去猜。
    /// 选哪一个由 AI 从 OpenStreetMap 候选里校准(`calibratedLookUp`),没配 AI 时退回自动挑。
    static func relocateAll(for trip: TravelTrip, context: ModelContext) async -> RelocateResult {
        PlaceGeocoder.resetMisses()
        verifiedCoordinates.removeAll()
        var result = RelocateResult()
        let targets = items(for: trip.uuid, in: context).filter {
            $0.travelKind?.isTransport != true && !geocodeQuery(for: $0).isEmpty
        }
        guard !targets.isEmpty else { return result }
        let contexts = await geocodeContexts(for: trip)
        guard !contexts.isEmpty else {
            result.destinationUnknown = true
            result.missed = targets.count
            return result
        }
        let tripItems = items(for: trip.uuid, in: context)
        let batch = Array(targets.prefix(geocodeBudget))
        let outcomes = await calibratedLookUp(batch, trip: trip, contexts: contexts, tripItems: tripItems)
        for item in batch {
            guard case .found(let coordinate, let byAI) = outcomes[item.uuid] else {
                result.missed += 1
                continue
            }
            if byAI { result.aiPicked += 1 }
            let moved = item.travelLatitude.map { abs($0 - coordinate.latitude) > 1e-5 } ?? true
                || item.travelLongitude.map { abs($0 - coordinate.longitude) > 1e-5 } ?? true
            if moved {
                item.travelLatitude = coordinate.latitude
                item.travelLongitude = coordinate.longitude
                if (item.travelPlaceName ?? "").isEmpty { item.travelPlaceName = item.title }
                result.moved += 1
            } else {
                result.unchanged += 1
            }
            verifiedCoordinates.insert(item.uuid)
        }
        result.missed += max(0, targets.count - geocodeBudget)
        try? context.save()
        return result
    }

    /// 查一条行程项的位置(按天列表里点了一个还没坐标的地点时用),查到就写进去。
    static func locate(_ item: MemoryItem, in trip: TravelTrip, context: ModelContext) async -> Bool {
        guard !geocodeQuery(for: item).isEmpty, item.travelKind?.isTransport != true else { return false }
        let contexts = await geocodeContexts(
            for: trip, existingAnchor: anchorCoordinate(for: trip, context: context))
        let outcomes = await calibratedLookUp([item], trip: trip, contexts: contexts,
                                              tripItems: items(for: trip.uuid, in: context))
        guard case .found(let coordinate, _) = outcomes[item.uuid] else { return false }
        item.travelLatitude = coordinate.latitude
        item.travelLongitude = coordinate.longitude
        if (item.travelPlaceName ?? "").isEmpty { item.travelPlaceName = item.title }
        try? context.save()
        return true
    }

    /// 已有行程项里的一个坐标(交通类除外——起降机场分处两地,拿它当锚点会把整趟偏到出发地去)。
    private static func anchorCoordinate(for trip: TravelTrip, context: ModelContext) -> CLLocationCoordinate2D? {
        items(for: trip.uuid, in: context)
            .first { $0.travelKind?.isTransport != true && $0.travelLatitude != nil }
            .flatMap { item in item.travelLatitude.flatMap { lat in
                item.travelLongitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
            } }
    }

    /// 把"有地名、没坐标"的行程项补上坐标,让它们能画到地图上。
    ///
    /// 坐标原本只有一条来路:用户在表单里点「搜索」选点(`PlaceSearchView`)。
    /// 手打的地名、AI 规划/调整生成的安排都没有坐标,地图那一页于是常年是空的。
    /// 这里在打开旅行详情时补一遍:按地名(带上旅行的城市/国家消歧)查一次,
    /// **查得到就记下来,查不到就留空**——留空的项照旧不上地图,
    /// 不编一个大概的位置糊弄(画错位置比不画更糟)。
    ///
    /// 航班不在此列:它的起降点是机场,名字来自订单解析,不拿地名搜索去猜。
    /// 一次最多补 `geocodeBudget` 条,逐条串行——`MKLocalSearch`/Nominatim 都有限流。
    static func fillMissingCoordinates(
        for trip: TravelTrip, context: ModelContext, limit: Int = geocodeBudget
    ) async {
        let pending = items(for: trip.uuid, in: context).filter { item in
            item.travelLatitude == nil && item.travelLongitude == nil
                && item.travelKind != .flight && !geocodeQuery(for: item).isEmpty
        }
        guard !pending.isEmpty else { return }
        // 认得出国家时可以拿已有行程项的坐标当锚点;认不出国家时 geocodeContext 不用它
        // ——没有国家判据的旅行正是当初最容易搜岔的那批,拿它自己存下的坐标当锚点只会把错误坐实。
        var contexts = await geocodeContexts(
            for: trip, existingAnchor: anchorCoordinate(for: trip, context: context))
        guard !contexts.isEmpty else { return }
        let tripItems = items(for: trip.uuid, in: context)
        var filled = false
        for item in pending.prefix(limit) {
            guard let (coordinate, index) = await lookUpWithContext(
                item, in: contexts, near: neighborCoordinates(of: item, among: tripItems)) else { continue }
            item.travelLatitude = coordinate.latitude
            item.travelLongitude = coordinate.longitude
            // 地名原来空着(用标题搜到的)时顺手补上,详情页那行才显示得出地点。
            if (item.travelPlaceName ?? "").isEmpty { item.travelPlaceName = item.title }
            contexts[index].anchor = contexts[index].anchor ?? coordinate
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

    /// 所有目的地的国家/地区(去重,按目的地顺序)。只有一个目的地时同 `expectedRegion`。
    static func expectedRegions(for trip: TravelTrip) -> [String] {
        let destinations = trip.destinations
        guard destinations.count > 1 else { return expectedRegion(for: trip).map { [$0] } ?? [] }
        var result: [String] = []
        for code in destinations.compactMap(\.regionCode) where !result.contains(code) {
            result.append(code)
        }
        return result
    }

    /// 每个目的地一条消歧词(选地点页用);只有一个目的地时同 `geocodeHint`。
    static func geocodeHints(for trip: TravelTrip) -> [String] {
        let destinations = trip.destinations
        guard destinations.count > 1 else { return geocodeHint(for: trip).map { [$0] } ?? [] }
        return destinations.compactMap(\.searchHint)
    }

    static func geocodeHint(for trip: TravelTrip) -> String? {
        let parts = [trip.city, trip.country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        // 两栏都空时用旅行名去掉「四日」「三日游」之类尾巴后的城市名,拼进搜索词才有用。
        return TravelDestination.cityCandidates(city: "", title: trip.title).first
    }

    /// 一次补全最多查几条。够覆盖一趟旅行的常规条数,又不至于一打开详情页就把
    /// `MKLocalSearch` 打到限流。
    static let geocodeBudget = 25

    /// 拿去搜的词:优先填过的地点名,没填就用标题("清水寺"这种本身就是地名)。
    private static func geocodeQuery(for item: MemoryItem) -> String {
        let place = (item.travelPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return place.isEmpty ? item.title.trimmingCharacters(in: .whitespacesAndNewlines) : place
    }

    /// 依次去查的词。**住宿先查酒店本身**(标题,「住新宿一带」这类 AI 写法先去掉
    /// 「住/一带」,见 `TravelDestination.lodgingQuery`),查不到再退回它填的地点(多半是
    /// 所在地区)——每天的路线从酒店出发、回到酒店,酒店钉在地区中心也比不上地图强。
    /// 其余行程项只查一个词。
    private static func geocodeQueries(for item: MemoryItem) -> [String] {
        guard item.travelKind == .lodging else { return [geocodeQuery(for: item)] }
        let candidates = [TravelDestination.lodgingQuery(item.title),
                          (item.travelPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty && !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    /// 多目的地时,不是首选的那几个目的地查到的结果要离它的城市锚点这么近才认。
    /// 「新宿」在北海道那边没查到、转去上海那边查时,苹果只给中国数据,会拿上海一家
    /// 同名酒店糊弄——离上海几千公里之外的地名本来就不该在上海找到。
    /// 放到 500 公里:北海道这种按整个道填的目的地,函馆到知床也有四百多公里。
    private static let fallbackDestinationRadius: CLLocationDistance = 500_000

    /// 同一天别的(非交通)行程项的坐标:用来猜这一条属于哪个目的地。
    private static func neighborCoordinates(of item: MemoryItem,
                                            among tripItems: [MemoryItem]) -> [CLLocationCoordinate2D] {
        guard let start = item.travelStart else { return [] }
        let calendar = Calendar.current
        return tripItems.compactMap { other in
            guard other.uuid != item.uuid, other.travelKind?.isTransport != true,
                  let otherStart = other.travelStart, calendar.isDate(otherStart, inSameDayAs: start),
                  let lat = other.travelLatitude, let lon = other.travelLongitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    private static func lookUp(_ item: MemoryItem, in contexts: [GeocodeContext],
                               near neighbors: [CLLocationCoordinate2D]) async -> CLLocationCoordinate2D? {
        await lookUpWithContext(item, in: contexts, near: neighbors)?.0
    }

    /// 多目的地时按哪个顺序去各个目的地里查:① 行程项自己的文字点名了哪个目的地
    /// (「上海外滩」)排最前;② 否则按同一天别的地点离哪个目的地的锚点近来排
    /// (同一天多半在同一个地方);③ 都没线索就按目的地填写的顺序。
    /// 排第一的照常查;后面的只认离那个目的地不远的结果(见 `fallbackDestinationRadius`)。
    /// 回传查到的坐标和它用的是哪一份判据(补全时拿它当那个目的地的锚点)。
    private static func lookUpWithContext(
        _ item: MemoryItem, in contexts: [GeocodeContext], near neighbors: [CLLocationCoordinate2D]
    ) async -> (CLLocationCoordinate2D, Int)? {
        guard contexts.count > 1 else {
            guard let only = contexts.first,
                  let coordinate = await lookUp(item, with: only) else { return nil }
            return (coordinate, 0)
        }
        for (rank, index) in destinationOrder(item, in: contexts, near: neighbors).enumerated() {
            let geo = contexts[index]
            if rank > 0 && geo.anchor == nil { continue }
            guard let coordinate = await lookUp(item, with: geo) else { continue }
            if rank > 0, let anchor = geo.anchor {
                let far = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                    > fallbackDestinationRadius
                if far { continue }
            }
            return (coordinate, index)
        }
        return nil
    }

    /// 多目的地时去各个目的地里查的先后(下标),规则见 `lookUpWithContext`。
    private static func destinationOrder(_ item: MemoryItem, in contexts: [GeocodeContext],
                                         near neighbors: [CLLocationCoordinate2D]) -> [Int] {
        guard contexts.count > 1 else { return Array(contexts.indices) }
        let text = [item.title, item.travelPlaceName ?? "", item.summary].joined(separator: " ")
        let destinations = contexts.map { $0.destination ?? TripDestination() }
        var order = TripDestination.preferredOrder(destinations, text: text)
        let anyMentioned = destinations.contains { TripDestination.mentioned($0, in: text) }
        if !anyMentioned, let center = neighbors.first {
            func distance(_ index: Int) -> CLLocationDistance {
                guard let anchor = contexts[index].anchor else { return .greatestFiniteMagnitude }
                return CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            }
            order = order.sorted { distance($0) < distance($1) }
        }
        return order
    }

    // MARK: - 重新选点的 AI 校准

    private static let calibrationLog = Logger(subsystem: "com.lodo.app", category: "TravelGeocode")

    /// 一条行程项重新选点的结果。
    enum RelocateOutcome {
        /// 找到了;`byAI` = 这个位置是 AI 从候选里挑的。
        case found(CLLocationCoordinate2D, byAI: Bool)
        /// 没找到,或者 AI 判定候选都不对——调用方保留原坐标。
        case notFound
    }

    /// 重新选点(「刷新地点位置」、点没坐标的地点当场查)用:每条先从 OpenStreetMap 拿
    /// 一组候选,再把整趟的候选**一次**交给 AI 挑最合理的(见 `PlaceCalibration`)。
    ///
    /// 退路:① OSM 一个候选都没有(或网络失败)→ 走原来的 `lookUpWithContext`(苹果地名
    /// 服务在前,国内的旅行主要靠它);② 没配 AI / AI 请求失败 / AI 没给这条结论 → 在
    /// 候选里按"离行程近 + 知名度"自动挑(`OSMGeocode.pick`,和原来一样);③ AI 明说
    /// 候选都不对 → 算没找到,**不退回自动挑**——那等于把 AI 否掉的那条又选回来。
    static func calibratedLookUp(_ targets: [MemoryItem], trip: TravelTrip,
                                 contexts: [GeocodeContext],
                                 tripItems: [MemoryItem]) async -> [UUID: RelocateOutcome] {
        var outcomes: [UUID: RelocateOutcome] = [:]
        var pending: [(item: MemoryItem, places: [OSMGeocode.Place], context: Int)] = []
        for item in targets {
            let neighbors = neighborCoordinates(of: item, among: tripItems)
            if let (places, index) = await osmCandidates(item, in: contexts, near: neighbors) {
                pending.append((item, places, index))
            } else if let coordinate = await lookUp(item, in: contexts, near: neighbors) {
                outcomes[item.uuid] = .found(coordinate, byAI: false)
            } else {
                outcomes[item.uuid] = .notFound
            }
        }
        guard !pending.isEmpty else { return outcomes }

        let calibrationItems = pending.map { entry in
            calibrationItem(entry.item, places: entry.places, anchor: contexts[entry.context].anchor, trip: trip)
        }
        var choices: [UUID: PlaceCalibration.Choice] = [:]
        if DeepSeekClient.isConfigured {
            do {
                choices = try await DeepSeekClient.calibratePlaces(
                    trip: calibrationTripLine(trip), items: calibrationItems)
            } catch {
                calibrationLog.error("AI calibration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // 每条:标题、候选数、AI 的结论(Console.app 里按 com.lodo.app / TravelGeocode 过滤)。
        for entry in pending {
            let verdict: String
            switch choices[entry.item.uuid] {
            case .pick(let index): verdict = "AI → #\(index + 1) \(entry.places[index].displayName)"
            case .none?: verdict = "AI → none"
            case nil: verdict = "auto"
            }
            calibrationLog.info("\(entry.item.title, privacy: .public): \(entry.places.count) candidates, \(verdict, privacy: .public)")
            for (index, place) in entry.places.enumerated() {
                calibrationLog.info("  #\(index + 1) \(place.name, privacy: .public) [\(place.addressType, privacy: .public) \(place.importance)] \(place.displayName, privacy: .public)")
            }
        }
        for entry in pending {
            let place: OSMGeocode.Place?
            let byAI: Bool
            switch choices[entry.item.uuid] {
            case .pick(let index):
                place = entry.places[index]
                byAI = true
            case .none?:
                outcomes[entry.item.uuid] = .notFound
                continue
            case nil:
                let geo = contexts[entry.context]
                place = OSMGeocode.pick(
                    entry.places, query: geocodeQueries(for: entry.item).first ?? entry.item.title,
                    region: geo.region,
                    anchor: geo.anchor.map { TravelCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
                    ?? entry.places.first
                byAI = false
            }
            outcomes[entry.item.uuid] = place.map {
                .found(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), byAI: byAI)
            } ?? .notFound
        }
        return outcomes
    }

    /// 按目的地顺序去 OSM 拿候选,第一个拿到候选的目的地就用它(不是首选的目的地只认
    /// 离它不远的,同 `lookUpWithContext`)。一个都没有时返回 nil。
    private static func osmCandidates(
        _ item: MemoryItem, in contexts: [GeocodeContext], near neighbors: [CLLocationCoordinate2D]
    ) async -> ([OSMGeocode.Place], Int)? {
        for (rank, index) in destinationOrder(item, in: contexts, near: neighbors).enumerated() {
            let geo = contexts[index]
            if rank > 0 && geo.anchor == nil { continue }
            // 标题和地点名两路都搜、合在一起给 AI(见 PlaceCalibration.queries)。
            var lists: [[OSMGeocode.Place]] = []
            for query in PlaceCalibration.queries(title: item.title, place: item.travelPlaceName ?? "",
                                                  isLodging: item.travelKind == .lodging) {
                guard var places = await PlaceGeocoder.osmCandidates(
                    for: query, anchor: geo.anchor, region: geo.region) else { continue }
                if rank > 0, let anchor = geo.anchor {
                    let center = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    places = places.filter {
                        center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                            <= fallbackDestinationRadius
                    }
                }
                lists.append(places)
            }
            let merged = PlaceCalibration.merge(lists)
            if !merged.isEmpty { return (merged, index) }
        }
        return nil
    }

    private static func calibrationItem(_ item: MemoryItem, places: [OSMGeocode.Place],
                                        anchor: CLLocationCoordinate2D?,
                                        trip: TravelTrip) -> PlaceCalibration.Item {
        let center = anchor.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let candidates = places.map { place in
            PlaceCalibration.Candidate(
                latitude: place.latitude, longitude: place.longitude, name: place.name,
                address: place.displayName, type: place.addressType, importance: place.importance,
                distanceKm: center.map {
                    $0.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) / 1000
                })
        }
        var when: String?
        if let start = item.travelStart {
            let calendar = Calendar.current
            let day = (calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.startDate),
                                               to: calendar.startOfDay(for: start)).day ?? 0) + 1
            when = "第 \(day) 天 " + start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        }
        return PlaceCalibration.Item(
            id: item.uuid, title: item.title, place: item.travelPlaceName ?? "",
            kind: item.travelKind == .lodging ? "住宿" : "地点", when: when,
            note: item.summary, candidates: candidates)
    }

    /// 清单开头那一行:旅行名、目的地、日期。
    private static func calibrationTripLine(_ trip: TravelTrip) -> String {
        let format = Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
        return "旅行:\(trip.title);目的地:\(trip.locationText ?? "未填");"
            + "日期:\(trip.startDate.formatted(format)) 至 \(trip.endDate.formatted(format))"
    }

    /// 按 `geocodeQueries` 的顺序查,第一个查到的就用。
    private static func lookUp(_ item: MemoryItem, with geo: GeocodeContext) async -> CLLocationCoordinate2D? {
        for query in geocodeQueries(for: item) {
            if let coordinate = await PlaceGeocoder.coordinate(
                for: query, hint: geo.hint, anchor: geo.anchor, region: geo.region) {
                return coordinate
            }
        }
        return nil
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
        let summary = TravelPlan.promptSummary(
            tripTitle: trip.title, days: trip.days,
            entries: entries(for: trip.uuid, in: context), includeIDs: includeIDs)
        // 同行人("这趟和谁去""给同行的人带什么礼物"要用得上);链接的人脉按人脉现在的名字。
        let names = travelerNames(trip, in: context)
        return names.isEmpty ? summary : summary + "\n同行人:" + names.joined(separator: "、")
    }

    static func travelerNames(_ trip: TravelTrip, in context: ModelContext) -> [String] {
        let travelers = trip.travelers
        guard !travelers.isEmpty else { return [] }
        let ids = Set(travelers.compactMap(\.contactUUID))
        var contactNames: [UUID: String] = [:]
        if !ids.isEmpty {
            let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
            for item in items where ids.contains(item.uuid) && item.isContact {
                contactNames[item.uuid] = item.title
            }
        }
        return travelers.map { traveler in
            traveler.contactUUID.flatMap { contactNames[$0] } ?? traveler.name
        }
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
