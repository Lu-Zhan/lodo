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
    /// 目的地城市与国家,都是用户手填的纯文字(可空),只用于展示,不参与定位或地图。
    public var city: String = ""
    public var country: String = ""
    public var createdAt: Date = Date.now

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

    /// "东京 · 日本";两个都空时返回 nil。
    public var locationText: String? {
        let parts = [city, country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
