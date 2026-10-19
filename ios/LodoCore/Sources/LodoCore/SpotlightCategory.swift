import Foundation

/// 系统搜索(Spotlight)里能搜到 lodo 的哪几类内容(单测 `SpotlightCategoryTests`)。
///
/// rawValue 同时是设置里存的值和索引的 domainIdentifier 后缀,**别改**。
/// 资产默认不进(锁屏下拉就能搜到身家不合适),健康类数据(体检、用药、经期、健康资料)
/// 一律不进索引、也不给开关。
public enum SpotlightCategory: String, CaseIterable, Identifiable {
    case task, countdown, memory, contact, trip, menu, asset

    public var id: String { rawValue }

    public static let defaultEnabled: Set<SpotlightCategory> = [.task, .countdown, .memory, .contact, .trip, .menu]

    public var domain: String { "com.lodo.app.\(rawValue)" }

    /// 一个条目在索引里的唯一标识:`<类别>:<uuid>`。
    public func identifier(_ uuid: UUID) -> String { "\(rawValue):\(uuid.uuidString)" }

    /// 从 Spotlight 点进来时拆回类别和 uuid。
    public static func parse(_ identifier: String) -> (SpotlightCategory, UUID)? {
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let category = SpotlightCategory(rawValue: parts[0]),
              let uuid = UUID(uuidString: parts[1]) else { return nil }
        return (category, uuid)
    }

    /// 设置里存的逗号串 → 开着的类别;nil(从没设过)= 默认那几类。
    public static func decode(_ raw: String?) -> Set<SpotlightCategory> {
        guard let raw else { return defaultEnabled }
        return Set(raw.split(separator: ",").compactMap { SpotlightCategory(rawValue: String($0)) })
    }

    public static func encode(_ categories: Set<SpotlightCategory>) -> String {
        allCases.filter(categories.contains).map(\.rawValue).joined(separator: ",")
    }
}
