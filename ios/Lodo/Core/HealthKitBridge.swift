import Foundation
import LodoCore
#if os(iOS)
import HealthKit
#endif

/// 读系统健康库,汇总成 `HealthReport`(纯逻辑在 LodoCore/HealthReport.swift)。
///
/// 三条约定,和 `LocationHelper` 一脉相承:
/// 1. **只读**——`requestAuthorization(toShare: [], read:)`,app 从不往健康库写数据;
/// 2. **静默降级**——未授权/无数据/查询报错一律返回空报告,不抛错打断调用方;
///    HealthKit 出于隐私不告诉 app "读权限被拒"(`authorizationStatus` 只反映写权限),
///    所以"拒绝"和"确实没数据"在我们这儿是同一种结果,UI 也按同一种空态处理;
/// 3. **只出汇总**——对外只给日级聚合值,逐条原始样本不出这个文件,更不进 prompt。
///
/// macOS 上 HealthKit 根本不存在,整份实现用 `#if os(iOS)` 门控,另一侧留同名空实现,
/// 调用方不写平台判断。
@MainActor
enum HealthKitBridge {

#if os(iOS)
    private static let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 请求只读授权。系统弹窗结果不告诉我们勾了哪几项,返回值只表示"弹窗流程本身
    /// 没出错"——真正有没有数据要靠 report() 的结果判断。
    @discardableResult
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes())
            return true
        } catch {
            return false
        }
    }

    /// 最近 days 天的日级汇总。任何一个指标查失败都只是少一条序列,不影响其余。
    static func report(days: Int) async -> HealthReport {
        guard isAvailable, days > 0 else { return .empty }
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date()).addingTimeInterval(86400)
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { return .empty }

        var series: [HealthSeries] = []
        for kind in HealthMetricKind.availableKinds() {
            let points: [HealthDailyPoint]
            if kind == .sleepHours {
                points = await sleepPoints(from: start, to: end, calendar: calendar)
            } else if let spec = quantitySpec(for: kind) {
                points = await quantityPoints(spec, from: start, to: end, calendar: calendar)
            } else {
                points = []
            }
            if !points.isEmpty {
                series.append(HealthSeries(kind: kind, points: points))
            }
        }
        return HealthReport(series: series, rangeDays: days)
    }

    // MARK: - 指标 → HealthKit 类型

    /// 一个数量型指标怎么查:类型、聚合方式、单位。睡眠不在此列(它是 category 样本)。
    private struct QuantitySpec {
        let type: HKQuantityType
        let options: HKStatisticsOptions
        let unit: HKUnit
    }

    private static func quantitySpec(for kind: HealthMetricKind) -> QuantitySpec? {
        switch kind {
        case .steps:
            return QuantitySpec(type: HKQuantityType(.stepCount),
                                options: .cumulativeSum, unit: .count())
        case .activeEnergy:
            return QuantitySpec(type: HKQuantityType(.activeEnergyBurned),
                                options: .cumulativeSum, unit: .kilocalorie())
        case .exerciseMinutes:
            return QuantitySpec(type: HKQuantityType(.appleExerciseTime),
                                options: .cumulativeSum, unit: .minute())
        case .restingHeartRate:
            return QuantitySpec(type: HKQuantityType(.restingHeartRate),
                                options: .discreteAverage,
                                unit: HKUnit.count().unitDivided(by: .minute()))
        case .hrv:
            return QuantitySpec(type: HKQuantityType(.heartRateVariabilitySDNN),
                                options: .discreteAverage, unit: .secondUnit(with: .milli))
        case .bodyMass:
            return QuantitySpec(type: HKQuantityType(.bodyMass),
                                options: .discreteAverage, unit: .gramUnit(with: .kilo))
        case .sleepHours:
            return nil
        }
    }

    private static func readTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for kind in HealthMetricKind.availableKinds() {
            if let spec = quantitySpec(for: kind) { types.insert(spec.type) }
        }
        return types
    }

    // MARK: - 查询

    /// 按天聚合数量型指标。用 async 的 `HKStatisticsCollectionQueryDescriptor`,
    /// 不再手工包一层 callback→continuation。
    private static func quantityPoints(
        _ spec: QuantitySpec, from start: Date, to end: Date, calendar: Calendar
    ) async -> [HealthDailyPoint] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: spec.type, predicate: predicate),
            options: spec.options,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1))
        guard let collection = try? await descriptor.result(for: store) else { return [] }

        var points: [HealthDailyPoint] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            let quantity = spec.options == .cumulativeSum
                ? statistics.sumQuantity()
                : statistics.averageQuantity()
            // 没有样本的那天直接跳过,不补 0——"那天没戴表"和"那天真的是 0"
            // 是两回事,补 0 会把日均算低。
            guard let quantity else { return }
            points.append(HealthDailyPoint(date: statistics.startDate,
                                           value: quantity.doubleValue(for: spec.unit)))
        }
        return points
    }

    /// 睡眠是 category 样本(一段一段的),按**结束那天**归属累计时长——
    /// 跨零点的一觉算作醒来那天的睡眠,和系统健康 app 的口径一致。
    private static func sleepPoints(
        from start: Date, to end: Date, calendar: Calendar
    ) async -> [HealthDailyPoint] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [])
        guard let samples = try? await descriptor.result(for: store) else { return [] }

        let asleepValues = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        var hoursByDay: [Date: Double] = [:]
        for sample in samples where asleepValues.contains(sample.value) {
            let day = calendar.startOfDay(for: sample.endDate)
            let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
            hoursByDay[day, default: 0] += hours
        }
        return hoursByDay.map { HealthDailyPoint(date: $0.key, value: $0.value) }
    }

#else

    /// macOS 没有 HealthKit。留同名空实现,调用方不用写 #if。
    static var isAvailable: Bool { false }

    @discardableResult
    static func requestAuthorization() async -> Bool { false }

    static func report(days: Int) async -> HealthReport { .empty }

#endif
}
