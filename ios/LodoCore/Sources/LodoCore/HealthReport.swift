import Foundation

/// 健康分析的纯逻辑层:指标定义、日级序列、均值/趋势计算,以及喂给 AI 的
/// 文字摘要。**刻意不 import HealthKit** —— LodoCore 还要在 macOS/watchOS 上
/// 编译,而 HealthKit 在 macOS 上根本不存在;真正读系统健康库的桥接放在 app 层
/// (`ios/Lodo/Core/HealthKitBridge.swift`),这里只吃它算好的数值,于是不用
/// 模拟器就能 `swift test`(和 Scheduler、MemorySearch 同一个分层思路)。

/// 一个健康指标。`titleKey`/`unitKey` 是给 UI 看的(走 LocalizedStrings 查表),
/// `promptName`/`promptUnit` 是给 AI 看的固定中文——prompt 三端逐字一致,不跟
/// 应用内语言走。
public enum HealthMetricKind: String, CaseIterable, Sendable {
    case steps
    case activeEnergy
    case exerciseMinutes
    case sleepHours
    case restingHeartRate
    case hrv
    case bodyMass

    public var titleKey: LK {
        switch self {
        case .steps: return .ios_core_health_steps
        case .activeEnergy: return .ios_core_health_active_energy
        case .exerciseMinutes: return .ios_core_health_exercise_minutes
        case .sleepHours: return .ios_core_health_sleep
        case .restingHeartRate: return .ios_core_health_resting_heart_rate
        case .hrv: return .ios_core_health_hrv
        case .bodyMass: return .ios_core_health_body_mass
        }
    }

    public var unitKey: LK {
        switch self {
        case .steps: return .ios_core_health_unit_steps
        case .activeEnergy: return .ios_core_health_unit_kcal
        case .exerciseMinutes: return .ios_core_health_unit_minutes
        case .sleepHours: return .ios_core_health_unit_hours
        case .restingHeartRate: return .ios_core_health_unit_bpm
        case .hrv: return .ios_core_health_unit_ms
        case .bodyMass: return .ios_core_health_unit_kg
        }
    }

    /// 喂给 AI 的固定中文名(prompt 不随应用内语言变化)。
    public var promptName: String {
        switch self {
        case .steps: return "步数"
        case .activeEnergy: return "活动能量"
        case .exerciseMinutes: return "锻炼时长"
        case .sleepHours: return "睡眠时长"
        case .restingHeartRate: return "静息心率"
        case .hrv: return "心率变异性"
        case .bodyMass: return "体重"
        }
    }

    public var promptUnit: String {
        switch self {
        case .steps: return "步"
        case .activeEnergy: return "千卡"
        case .exerciseMinutes: return "分钟"
        case .sleepHours: return "小时"
        case .restingHeartRate: return "次/分"
        case .hrv: return "毫秒"
        case .bodyMass: return "公斤"
        }
    }

    public var systemImage: String {
        switch self {
        case .steps: return "figure.walk"
        case .activeEnergy: return "flame"
        case .exerciseMinutes: return "figure.run"
        case .sleepHours: return "bed.double"
        case .restingHeartRate: return "heart"
        case .hrv: return "waveform.path.ecg"
        case .bodyMass: return "scalemass"
        }
    }

    /// 小数位数:步数/能量/心率这类整数展示,睡眠时长和体重留一位。
    public var fractionDigits: Int {
        switch self {
        case .sleepHours, .bodyMass: return 1
        default: return 0
        }
    }

    public func format(_ value: Double) -> String {
        String(format: "%.\(fractionDigits)f", value)
    }

    /// 值越大越好的指标(趋势箭头的颜色语义由调用方按这个判断)。
    /// 心率/体重不在此列——它们没有"越高越好"的单一方向,UI 上只给中性箭头。
    public var higherIsBetter: Bool {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .sleepHours, .hrv: return true
        case .restingHeartRate, .bodyMass: return false
        }
    }

    /// 当前系统能提供的指标全集。iOS 27 若新增了指标,门控**只加在这一处**
    /// (`if #available(iOS 27.0, macOS 27.0, *) { kinds.append(...) }`),
    /// 调用方拿到几个就画几个,不用各自写 #available——和 LiquidGlass.swift
    /// 把 iOS 26 门控收进封装是同一个约定。
    public static func availableKinds() -> [HealthMetricKind] {
        allCases
    }
}

/// 某个指标在某一天的聚合值(步数是当天累计,心率是当天平均,由桥接层决定)。
public struct HealthDailyPoint: Equatable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// 一个指标的日级序列。构造时按日期升序排好,后面的统计都假定这个顺序。
public struct HealthSeries: Equatable, Sendable {
    public let kind: HealthMetricKind
    public let points: [HealthDailyPoint]

    public init(kind: HealthMetricKind, points: [HealthDailyPoint]) {
        self.kind = kind
        self.points = points.sorted { $0.date < $1.date }
    }
}

/// 一次健康数据快照:若干指标各自的日级序列 + 覆盖天数。
public struct HealthReport: Equatable, Sendable {
    public let series: [HealthSeries]
    public let rangeDays: Int

    public init(series: [HealthSeries], rangeDays: Int) {
        self.series = series.filter { !$0.points.isEmpty }
        self.rangeDays = rangeDays
    }

    public static let empty = HealthReport(series: [], rangeDays: 0)

    public var isEmpty: Bool { series.isEmpty }

    public func series(_ kind: HealthMetricKind) -> HealthSeries? {
        series.first { $0.kind == kind }
    }

    /// 覆盖区间内的日均值;没有数据返回 nil(而不是 0——"没测"和"是 0"是两回事)。
    public func average(_ kind: HealthMetricKind) -> Double? {
        guard let points = series(kind)?.points, !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.value } / Double(points.count)
    }

    /// 最新一天的值。
    public func latest(_ kind: HealthMetricKind) -> Double? {
        series(kind)?.points.last?.value
    }

    /// 最近 7 天均值相对之前 7 天均值的变化比例(0.05 = 涨了 5%)。
    /// 两段任一没有数据、或基准段均值为 0 时返回 nil——除以 0 得不出百分比,
    /// 与其给个 ∞ 不如老实说"算不出来"。
    public func trend(_ kind: HealthMetricKind, window: Int = 7) -> Double? {
        guard let points = series(kind)?.points, points.count > window else { return nil }
        let recent = Array(points.suffix(window))
        let earlier = Array(points.dropLast(window).suffix(window))
        guard !recent.isEmpty, !earlier.isEmpty else { return nil }
        let recentAvg = recent.reduce(0) { $0 + $1.value } / Double(recent.count)
        let earlierAvg = earlier.reduce(0) { $0 + $1.value } / Double(earlier.count)
        guard earlierAvg != 0 else { return nil }
        return (recentAvg - earlierAvg) / earlierAvg
    }

    /// 格式化成喂给 AI 的一段中文文字。和 OverviewView 把待办列表拼成 summary
    /// 传给 suggestTodayHandling 是同一个套路:**只发汇总统计,不发逐条原始记录**
    /// ——健康数据敏感,能少发一点是一点。
    public func promptSummary() -> String {
        guard !isEmpty else { return "" }
        var lines = ["最近 \(rangeDays) 天的健康数据:"]
        for item in series {
            let kind = item.kind
            var line = "- \(kind.promptName):日均 \(kind.format(average(kind) ?? 0)) \(kind.promptUnit)"
            if let latest = latest(kind) {
                line += ",最近一天 \(kind.format(latest)) \(kind.promptUnit)"
            }
            if let trend = trend(kind) {
                let percent = String(format: "%.0f", abs(trend) * 100)
                line += trend >= 0 ? ",较上一周期上升 \(percent)%" : ",较上一周期下降 \(percent)%"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// `DeepSeekClient.analyzeHealth` 的返回:一段分析正文 + 最多 3 条具体建议。
public struct HealthAnalysis: Equatable, Sendable {
    public let analysis: String
    public let suggestions: [String]

    public init(analysis: String, suggestions: [String]) {
        self.analysis = analysis
        self.suggestions = suggestions
    }
}
