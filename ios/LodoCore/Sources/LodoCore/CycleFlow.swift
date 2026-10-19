import Foundation
import SwiftData

/// 经期出血量(单测 `CycleFlowTests`)。手记一天一条(`PeriodFlowRecord`),健康 App 的经期流量
/// 只读、只在内存里合并,不落进手记表。
///
/// 三种状态要分清:**没记**(那天没有任何记录,显示「未记」)、**无**(记了,没有出血)、
/// **有出血没分档**(健康 App 里常见)。没记绝不能当成「无」。

/// 出血量档位。rawValue 是存储值(`PeriodFlowRecord.levelRaw`),**别改**。
/// 和 HealthKit 的对应:none ↔ .none、light ↔ .light、medium ↔ .medium、heavy ↔ .heavy、
/// unspecified ↔ .unspecified。
public enum CycleFlowLevel: String, CaseIterable, Sendable {
    case none, light, medium, heavy, unspecified

    /// 比出血多少用的序(none 最低;unspecified 只表示"有",不参与比大小)。
    var rank: Int {
        switch self {
        case .none: return 0
        case .light: return 1
        case .medium: return 2
        case .heavy: return 3
        case .unspecified: return -1
        }
    }

    /// 算不算"有出血"。
    public var isBleeding: Bool { self != .none }

    /// 首页 / 今天那一排给用户点的四档(「有出血,未分档」不给手点,健康 App 读来时才有)。
    public static let selectable: [CycleFlowLevel] = [.none, .light, .medium, .heavy]
}

/// 一天的出血量记录(手记)。一天只该有一条,但 CloudKit 不支持唯一约束:读的时候按
/// `dayKey` 归并、取 `updatedAt` 最新的(`CycleFlow.resolve`);**清除写墓碑**(`isDeleted`)
/// 而不是删行,免得另一台设备上的旧副本让它复活。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class PeriodFlowRecord {
    public var uuid: UUID = UUID()
    /// 记的是哪一天:"yyyy-MM-dd"(公历,按记的时候所在地的日子;旅行换时区也不会挪到前一天)。
    public var dayKey: String = ""
    /// `CycleFlowLevel` 的 rawValue;认不出的原样保留(显示「未知档位」,不猜)。
    public var levelRaw: String = ""
    public var updatedAt: Date = Date.now
    /// 清除了这一天的记录。
    public var isDeleted: Bool = false
    public var createdAt: Date = Date.now

    public init(uuid: UUID = UUID(), dayKey: String, level: CycleFlowLevel, updatedAt: Date = .now) {
        self.uuid = uuid
        self.dayKey = dayKey
        self.levelRaw = level.rawValue
        self.updatedAt = updatedAt
        self.createdAt = updatedAt
    }

    public var entry: CycleFlow.ManualEntry {
        CycleFlow.ManualEntry(uuid: uuid, dayKey: dayKey, levelRaw: levelRaw, updatedAt: updatedAt,
                              isDeleted: isDeleted)
    }
}

public enum CycleFlow {
    /// 手记的一条(值快照)。
    public struct ManualEntry: Equatable, Sendable {
        public var uuid: UUID
        public var dayKey: String
        public var levelRaw: String
        public var updatedAt: Date
        public var isDeleted: Bool

        public init(uuid: UUID = UUID(), dayKey: String, levelRaw: String, updatedAt: Date,
                    isDeleted: Bool = false) {
            self.uuid = uuid
            self.dayKey = dayKey
            self.levelRaw = levelRaw
            self.updatedAt = updatedAt
            self.isDeleted = isDeleted
        }
    }

    /// 健康 App 的一条经期流量样本。
    public struct HealthSample: Equatable, Sendable {
        public var dayKey: String
        public var level: CycleFlowLevel

        public init(dayKey: String, level: CycleFlowLevel) {
            self.dayKey = dayKey
            self.level = level
        }
    }

    public enum Source: Equatable, Sendable { case manual, health }

    /// 归并后的一天。`level` 为 nil = 手记里存了认不出的档位(老版本/新版本写的),原值在 `raw`。
    public struct Day: Equatable, Sendable {
        public var level: CycleFlowLevel?
        public var raw: String
        public var source: Source
        /// 健康 App 里这一天既记了「无」又记了出血(手记覆盖了的不算)。
        public var conflict: Bool = false
    }

    /// 按天归并:手记优先(同一天多条取 `updatedAt` 最新的,一样新按 uuid 定);最新那条是墓碑
    /// 就当这天没手记,露出健康 App 的。健康 App 同一天多条:有明确档位取最高的,只有
    /// 「有出血没分档」就是它,只有「无」就是无。
    public static func resolve(manual: [ManualEntry], health: [HealthSample]) -> [String: Day] {
        var result: [String: Day] = [:]
        for (key, samples) in Dictionary(grouping: health, by: \.dayKey) {
            let levels = samples.map(\.level)
            let level: CycleFlowLevel
            if let top = levels.filter({ $0.rank > 0 }).max(by: { $0.rank < $1.rank }) {
                level = top
            } else if levels.contains(.unspecified) {
                level = .unspecified
            } else {
                level = .none
            }
            let conflict = levels.contains(.none) && levels.contains { $0.isBleeding }
            result[key] = Day(level: level, raw: level.rawValue, source: .health, conflict: conflict)
        }
        for (key, entries) in Dictionary(grouping: manual, by: \.dayKey) {
            guard let latest = entries.max(by: { a, b in
                a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : a.uuid.uuidString < b.uuid.uuidString
            }), !latest.isDeleted else { continue }
            result[key] = Day(level: CycleFlowLevel(rawValue: latest.levelRaw), raw: latest.levelRaw,
                              source: .manual)
        }
        return result
    }

    /// 这一天的 key:"yyyy-MM-dd"。**固定按公历**、用 `calendar` 的时区取年月日——用户把系统
    /// 日历换成佛历/和历时,同一天也得是同一个 key。
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// key → 那天 0 点;格式不是严格的 "yyyy-MM-dd"、或者日子不存在,返回 nil。
    public static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let chars = Array(key)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-",
              chars.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || ("0"..."9").contains($0.element) })
        else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        let g = gregorian(calendar)
        guard parts.count == 3, (1...12).contains(parts[1]),
              let date = g.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              g.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// 一段日子里每天的 key,从早到晚(含首尾)。
    public static func dayKeys(from start: Date, through end: Date, calendar: Calendar = .current) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last, keys.count < 60 {
            keys.append(dayKey(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }
}
