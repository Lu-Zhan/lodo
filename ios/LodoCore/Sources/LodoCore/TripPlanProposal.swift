import Foundation

/// AI「规划行程」(`plan_trip`)给出的一份安排。和 `ParsedTravelItem`(订单导入)
/// 一样**不直接落库**——自动规划是建议而不是事实,用户在聊天卡片上点「写入行程」
/// 才变成真正的行程项。
///
/// 整个结构序列化进 `AgentMessage.tripPlanSnapshotData`:提案阶段只有规划内容,
/// 写入之后把 `appliedTripUUID`/`appliedItemUUIDs` 一起写回,卡片据此显示
/// "已写入"并提供撤销;撤销把 `reverted` 置 true,再点一次按同一份内容重新写入
/// (和新建待办结果卡片那颗对号开关同一个思路)。后加的字段一律 Optional,
/// 老消息缺键也能解出来。
public struct TripPlanProposal: Codable, Equatable, Sendable {
    /// 旅行名。规划的是已有旅行时,模型会原样填那次旅行的名字,写入时按它匹配。
    public var tripTitle: String
    public var startDate: Date
    public var endDate: Date
    /// 一两句规划思路,卡片顶上那行。
    public var summary: String
    public var items: [TripPlanItem]

    /// 写入到了哪次旅行。nil = 还没写入过。
    public var appliedTripUUID: UUID?
    /// 这次写入新建出来的行程项,撤销时按它删。
    public var appliedItemUUIDs: [UUID]?
    /// 旅行本身是不是这次写入新建的(是的话撤销时连旅行一起删)。
    public var createdTrip: Bool?
    /// 写入后又被撤销了。
    public var reverted: Bool?

    public init(tripTitle: String, startDate: Date, endDate: Date, summary: String = "",
                items: [TripPlanItem]) {
        self.tripTitle = tripTitle
        self.startDate = startDate
        self.endDate = endDate
        self.summary = summary
        self.items = items
    }

    /// 当前是否处于"已写入、没撤销"。
    public var isApplied: Bool { appliedTripUUID != nil && reverted != true }

    /// 覆盖的每一天(0 点),和 `TravelTrip.days` 同一套算法。
    public func days(calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let count = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// 转成 `TravelEntry`,复用 `TravelPlan` 的按天分组/排序给卡片用。
    /// id 按下标派生成稳定值,同一份规划重复渲染时 ForEach 不会抖。
    public var entries: [TravelEntry] {
        items.enumerated().map { index, item in
            TravelEntry(id: Self.stableID(index), kind: item.kind, title: item.title,
                        summary: item.note, start: item.start, end: item.end,
                        price: item.price, currency: item.currency ?? "CNY",
                        placeName: item.placeName)
        }
    }

    private static func stableID(_ index: Int) -> UUID {
        let hex = String(format: "%012x", index)
        return UUID(uuidString: "00000000-0000-4000-8000-\(hex)") ?? UUID()
    }
}

/// 规划里的一条安排。只有地点和住宿——**不生成航班**:航班号和时刻编不出来,
/// 编了反而害人(照着假的起飞时间去机场)。
public struct TripPlanItem: Codable, Equatable, Sendable {
    public var kindRaw: String
    public var title: String
    public var note: String
    public var start: Date?
    public var end: Date?
    public var placeName: String?
    public var price: Double?
    public var currency: String?

    public init(kind: TravelItemKind, title: String, note: String = "", start: Date? = nil,
                end: Date? = nil, placeName: String? = nil, price: Double? = nil,
                currency: String? = nil) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.note = note
        self.start = start
        self.end = end
        self.placeName = placeName
        self.price = price
        self.currency = currency
    }

    public var kind: TravelItemKind { TravelItemKind(rawValue: kindRaw) ?? .place }
}
