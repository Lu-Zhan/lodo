import Foundation

/// lodo 手记的经期 → 健康 App 的经期流量样本(单测 `CycleHealthExportTests`,不 import HealthKit)。
///
/// 写回健康 App 是**对账**,不是逐处挂钩子:每次按手记算出"健康 App 里 lodo 写的那份应该长什么样"
/// (`desired`),再和健康 App 里现有的、lodo 自己写过的样本比(`plan`),多的删、少的补、
/// 一样的不动——健康库本身就是账本,不另存一份对照表。
///
/// 几条口径:
/// - **只写手记确认过的经期日子**:有结束日的写开始到结束每一天;还开着的写开始到今天,
///   但最多写典型经期天数(`openLimit`),忘了点结束不会一天天往健康 App 里写出血。
/// - 每天的档位取那天的手记出血量(墓碑和认不出的档位当没记),没记就是「有出血,未分档」。
///   经期外单独记的出血量不写(lodo 里那不算一次经期,写进去健康 App 会多出一次经期)。
/// - 健康 App 里那天**已经有别的来源**(用户在健康 App / 别的 app 记的)就不写,免得同一天两条。
/// - 第一天带「周期开始」标记(HealthKit 要求每条经期样本都带这个元数据)。
public enum CycleHealthExport {
    /// 要写进健康 App 的一天。
    public struct Day: Equatable, Hashable, Sendable {
        public var dayKey: String
        public var level: CycleFlowLevel
        public var isStart: Bool

        public init(dayKey: String, level: CycleFlowLevel, isStart: Bool) {
            self.dayKey = dayKey
            self.level = level
            self.isStart = isStart
        }
    }

    /// 健康 App 里 lodo 自己写过的一条样本。
    public struct Existing: Equatable, Sendable {
        public var id: UUID
        public var day: Day

        public init(id: UUID, day: Day) {
            self.id = id
            self.day = day
        }
    }

    public struct Plan: Equatable, Sendable {
        public var delete: [UUID]
        public var add: [Day]

        public var isEmpty: Bool { delete.isEmpty && add.isEmpty }
    }

    /// 按手记算出健康 App 里应有的 lodo 样本,按日子 key 索引。`since` 之前的日子不管
    /// (健康 App 只往回读这么久,窗口外的不能判断有没有、也就不增不删)。
    public static func desired(manual: [CyclePlan.Period], flows: [CycleFlow.ManualEntry],
                               foreignDays: Set<String>, since: Date, today: Date,
                               openLimit: Int, calendar: Calendar = .current) -> [String: Day] {
        let todayStart = calendar.startOfDay(for: today)
        let sinceStart = calendar.startOfDay(for: since)
        let levels = CycleFlow.resolve(manual: flows, health: [])
        // 同一天开始的手记只留一条,和界面上看到的一致。
        let periods = CyclePlan.merge(manual: manual.filter { !$0.fromHealth }, health: [],
                                      today: today, calendar: calendar)
        var result: [String: Day] = [:]
        for period in periods where period.start <= todayStart {
            var last: Date
            if let end = period.end {
                last = end
            } else {
                last = calendar.date(byAdding: .day, value: max(openLimit, 1) - 1, to: period.start)
                    ?? period.start
            }
            last = min(last, todayStart)
            for (offset, key) in CycleFlow.dayKeys(from: period.start, through: last, calendar: calendar).enumerated() {
                guard !foreignDays.contains(key),
                      let date = CycleFlow.date(fromKey: key, calendar: calendar), date >= sinceStart
                else { continue }
                let level = levels[key]?.level ?? .unspecified
                let isStart = offset == 0
                if let existing = result[key] {
                    // 两段手记重叠(一段忘了结束又开了一段):那天只写一条,有一段从这天开始就算开始。
                    result[key]?.isStart = existing.isStart || isStart
                } else {
                    result[key] = Day(dayKey: key, level: level, isStart: isStart)
                }
            }
        }
        return result
    }

    /// 现有的 lodo 样本 → 应有的:每天留一条完全一样的,其余删掉;没有的补上。
    public static func plan(desired: [String: Day], existing: [Existing]) -> Plan {
        var delete: [UUID] = []
        var add: [Day] = []
        let grouped = Dictionary(grouping: existing, by: \.day.dayKey)
        for (key, samples) in grouped {
            guard let want = desired[key] else {
                delete += samples.map(\.id)
                continue
            }
            let sorted = samples.sorted { $0.id.uuidString < $1.id.uuidString }
            if let keep = sorted.first(where: { $0.day == want }) {
                delete += sorted.filter { $0.id != keep.id }.map(\.id)
            } else {
                delete += sorted.map(\.id)
                add.append(want)
            }
        }
        for (key, want) in desired where grouped[key] == nil {
            add.append(want)
        }
        return Plan(delete: delete.sorted { $0.uuidString < $1.uuidString },
                    add: add.sorted { $0.dayKey < $1.dayKey })
    }
}
