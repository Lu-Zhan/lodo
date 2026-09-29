import Foundation
import SwiftData

/// 一次旅行。行程项本身**不是**独立模型,而是打了保留标签「旅行」的 `MemoryItem`
/// (见 `MemoryItem.travelTripUUID` 那组字段)——和资产/人脉同一套思路,好处是
/// 订票确认单、酒店 PDF 直接当记忆条目的附件存,能被记忆搜索和"问 AI"命中。
/// 这里只存"这趟旅行本身"的信息,与行程项靠 uuid 关联(不建 SwiftData 关系:
/// 与 ContactRelationship 同样的取舍,关系在 CloudKit 同步下更容易出岔子)。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class TravelTrip {
    public var uuid: UUID = UUID()
    public var title: String = ""
    /// 出发日与返程日(只取日期部分参与按天分组,时分秒不参与)。
    public var startDate: Date = Date.now
    public var endDate: Date = Date.now
    public var notes: String = ""
    /// 第一个目的地的城市与国家,都是用户手填的纯文字(可空)。给地名搜索当消歧判据
    /// (见 `TravelStore.geocodeContext`)。
    public var city: String = ""
    public var country: String = ""
    /// 第二个起的目的地(`TripDestination` 数组的 JSON 串,空串 = 只有一个目的地),
    /// 读写走 `destinations`。
    public var extraDestinations: String = ""
    public var createdAt: Date = Date.now
    /// 标题前的 emoji(编辑旅行里改),空串 = 用默认的 ✈️,读的时候走 `displayEmoji`。
    public var emoji: String = ""
    /// 共享身份(`SharedTripRole` 的存储值):空串 = 没共享,`owner` = 我分享出去的,
    /// `participant` = 别人分享给我的。见 `SharedTripSync`。
    public var shareRoleRaw: String = ""
    /// 共享 zone 的 owner(`CKRecordZone.ID.ownerName`);没共享时为空串。
    public var shareZoneOwner: String = ""
    /// 同行人(`TripTraveler` 数组的 JSON 串,空串 = 没填),读写走 `travelers`。
    public var travelersData: String = ""

    public init(uuid: UUID = UUID(), title: String = "", startDate: Date = .now,
                endDate: Date = .now, notes: String = "", city: String = "",
                country: String = "", createdAt: Date = .now) {
        self.uuid = uuid
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.city = city
        self.country = country
        self.createdAt = createdAt
    }

    public static let defaultEmoji = "✈️"

    /// 标题前显示的 emoji:没设置过就是 ✈️。
    public var displayEmoji: String { emoji.isEmpty ? Self.defaultEmoji : emoji }

    /// 编辑框里输入的东西只留**最后一个** emoji(换一个时直接在后面打新的就行,
    /// 不用先删旧的);一个 emoji 都没有时返回空串(= 用默认)。组合 emoji(国旗、
    /// 带肤色、家庭)是一个字符,整颗保留。
    public static func normalizedEmoji(_ text: String) -> String {
        guard let last = text.last(where: \.isEmojiCharacter) else { return "" }
        return String(last)
    }

    /// "东京 · 日本";多个目的地用「+」连起来("北海道 · 日本 + 上海 · 中国");
    /// 一个都没填时返回 nil。
    public var locationText: String? {
        let parts = destinations.map(\.displayText)
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    /// 旅行天数(含首尾),按日历天算,至少 1 天。
    public var dayCount: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
    }

    /// 旅行的每一天(0 点),供按天视图铺日期用。
    public var days: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        return (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// now 落在行程区间内。
    public func isOngoing(now: Date = .now) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
        else { return false }
        return now >= start && now < end
    }

    public func isUpcoming(now: Date = .now) -> Bool {
        Calendar.current.startOfDay(for: startDate) > now
    }
}

extension Character {
    /// 是不是一个 emoji:默认按 emoji 显示的码位(✈ 这类要带 FE0F 变体选择符才算,
    /// 所以看"标量多于一个");单独的数字、# 虽然 isEmoji 为 true,不算。
    var isEmojiCharacter: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation
            || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
