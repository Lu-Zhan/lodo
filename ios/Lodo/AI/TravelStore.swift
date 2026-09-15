import Foundation
import SwiftData
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
        context: ModelContext
    ) -> MemoryItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = MemoryItem(
            kind: .text, title: trimmed, summary: note,
            tags: [MemoryItem.travelTagName],
            sourceText: MemorySearch.truncate(searchText(
                title: trimmed, note: note, code: code,
                placeName: placeName, originName: originName)),
            status: .ready,
            travelTripUUID: tripUUID, travelKind: kind, travelStart: start, travelEnd: end,
            travelPrice: price, travelCurrency: currency,
            travelPlaceName: placeName, travelLatitude: latitude, travelLongitude: longitude,
            travelOriginName: originName, travelOriginLatitude: originLatitude,
            travelOriginLongitude: originLongitude, travelCode: code)
        context.insert(item)
        MemoryPipeline.finishStructuredSave(item, context: context)
        return item
    }

    /// 编辑已有行程项(表单保存)。
    static func update(
        _ item: MemoryItem, kind: TravelItemKind, title: String, note: String,
        code: String?, start: Date?, end: Date?, price: Double?, currency: String?,
        placeName: String?, latitude: Double?, longitude: Double?,
        originName: String?, originLatitude: Double?, originLongitude: Double?,
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
        item.sourceText = MemorySearch.truncate(searchText(
            title: trimmed, note: note, code: code,
            placeName: placeName, originName: originName))
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
               placeName: parsed.placeName, originName: parsed.originName, context: context)
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

    // MARK: - 给 AI

    /// `read_trip` 工具的返回。name 为空时挑"正在进行的那次,否则最近一次"。
    /// 一条旅行都没有时返回 nil,由调用方给"还没记过旅行"的说法。
    static func promptSummary(name: String, in context: ModelContext) -> String? {
        let all = trips(in: context)
        guard !all.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trip: TravelTrip
        if !trimmed.isEmpty,
           let matched = all.first(where: { $0.title.localizedStandardContains(trimmed) }) {
            trip = matched
        } else if let ongoing = all.first(where: { $0.isOngoing() }) {
            trip = ongoing
        } else if let upcoming = all.filter({ $0.isUpcoming() }).last {
            // trips 是按出发日倒序的,最后一条 upcoming 就是最近要出发的那次。
            trip = upcoming
        } else {
            trip = all[0]
        }
        return TravelPlan.promptSummary(
            tripTitle: trip.title, days: trip.days,
            entries: entries(for: trip.uuid, in: context))
    }

    /// 行程项落进记忆库时可被搜索到的正文(地名/航班号都该能搜出来)。
    private static func searchText(
        title: String, note: String, code: String?, placeName: String?, originName: String?
    ) -> String {
        [title, note, code ?? "", placeName ?? "", originName ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
