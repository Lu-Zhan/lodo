import Foundation
import LodoCore
import HealthKit

/// 读系统健康库,汇总成 `HealthReport`(纯逻辑在 LodoCore/HealthReport.swift)。
///
/// 三条约定,和 `LocationHelper` 一脉相承:
/// 1. **只读**——`requestAuthorization(toShare: [], read:)`;唯一的例外是经期:用户打开
///    「与健康 App 同步」后,把手记的经期写成经期流量样本(只写经期这一种,见「经期」那段);
/// 2. **静默降级**——未授权/无数据/查询报错一律返回空报告,不抛错打断调用方;
///    HealthKit 出于隐私不告诉 app "读权限被拒"(`authorizationStatus` 只反映写权限),
///    所以"拒绝"和"确实没数据"在我们这儿是同一种结果,UI 也按同一种空态处理;
/// 3. **只出汇总**——对外只给日级聚合值,逐条原始样本不出这个文件,更不进 prompt。
///
/// iOS 与 macOS 同一份实现。macOS 有 HealthKit 框架,但 Mac 上没有健康数据
/// (`isHealthDataAvailable()` 恒为 false),所以那边一路走 `isAvailable` 的空报告,
/// 不会弹授权、也不需要 healthkit entitlement;UI 按 `isAvailable` 显示"这台设备没有
/// 健康数据"。哪天 Mac 上有了健康库,这里不用改。
@MainActor
enum HealthKitBridge {

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
        // 性别只用来决定「经期」默认开不开(`CyclePlan.isEnabled`),不出这台设备。
        var types: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis),
                                        HKCharacteristicType(.biologicalSex)]
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

    // MARK: - 性别(决定经期默认开关)

    /// 健康 App 里填的性别。没授权/没填/读失败一律 unknown。读到就记进 UserDefaults
    /// (`biologicalSexKey`),设置页和健康页按它判断「自动」时经期开不开——Mac 和没开
    /// 健康分析时读不到,就停在上次记下的值(从没读到过就是 unknown,经期默认关)。
    static func refreshBiologicalSex() {
        guard isAvailable, let object = try? store.biologicalSex() else { return }
        let sex: CyclePlan.Sex
        switch object.biologicalSex {
        case .female: sex = .female
        case .male: sex = .male
        case .other: sex = .other
        default: sex = .unknown
        }
        UserDefaults.standard.set(sex.rawValue, forKey: AppSettings.biologicalSexKey)
    }

    // MARK: - 经期

    /// 经期的权限单独请求:不放进上面那张总授权单里,免得没用这个功能的人也被问一遍经期。
    /// `write` = 开了「与健康 App 同步」,连写权限一起问。
    @discardableResult
    static func requestCycleAuthorization(write: Bool = false) async -> Bool {
        guard isAvailable else { return false }
        let type = HKCategoryType(.menstrualFlow)
        do {
            try await store.requestAuthorization(toShare: write ? [type] : [], read: [type])
            return true
        } catch {
            return false
        }
    }

    /// 经期写权限给了没有(HealthKit 只告诉 app 写权限的状态,读权限不告诉)。
    static var cycleWriteAuthorized: Bool {
        isAvailable && store.authorizationStatus(for: HKCategoryType(.menstrualFlow)) == .sharingAuthorized
    }

    /// 健康 App 里的一条经期流量样本。`fromLodo` = lodo 自己写进去的(读经期时要排除,
    /// 不然自己写的又当成健康 App 的数据读回来)。
    struct CycleFlowSample {
        let id: UUID
        let date: Date
        let level: CycleFlowLevel
        let isStart: Bool
        let fromLodo: Bool
    }

    /// 最近 days 天健康 App 的经期流量样本(日子 + 档位,含「无」)。只读日子和档位,别的不读。
    /// `nil` = 查询失败(和"一条都没有"分开:写回时查不到现状就不能对账,否则会重复写)。
    static func menstrualFlowSamples(days: Int) async -> [CycleFlowSample]? {
        guard isAvailable, days > 0 else { return [] }
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.menstrualFlow), predicate: predicate)],
            sortDescriptors: [])
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let ownBundle = HKSource.default().bundleIdentifier
        return samples.map { sample in
            CycleFlowSample(
                id: sample.uuid, date: sample.startDate, level: flowLevel(sample.value),
                isStart: (sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? NSNumber)?.boolValue ?? false,
                fromLodo: sample.sourceRevision.source.bundleIdentifier == ownBundle)
        }
    }

    /// 写一批经期流量样本(每天一条,0 点到次日 0 点)。带 sync identifier(按日子),
    /// 两台设备同一天各写一条时健康 App 只留版本新的那条。
    static func saveMenstrualFlow(_ days: [CycleHealthExport.Day]) async -> Bool {
        guard isAvailable, !days.isEmpty else { return true }
        let calendar = Calendar.current
        let type = HKCategoryType(.menstrualFlow)
        let version = Int(Date().timeIntervalSince1970)
        let samples: [HKCategorySample] = days.compactMap { day in
            guard let start = CycleFlow.date(fromKey: day.dayKey, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return HKCategorySample(
                type: type, value: healthValue(day.level), start: start, end: end,
                metadata: [HKMetadataKeyMenstrualCycleStart: day.isStart,
                           HKMetadataKeySyncIdentifier: "lodo-cycle-\(day.dayKey)",
                           HKMetadataKeySyncVersion: version])
        }
        do {
            try await store.save(samples)
            return true
        } catch {
            return false
        }
    }

    /// 删掉 lodo 自己写过的几条经期样本(HealthKit 只允许删本 app 写的)。
    static func deleteMenstrualFlow(ids: [UUID]) async -> Bool {
        guard isAvailable, !ids.isEmpty else { return true }
        do {
            _ = try await store.deleteObjects(of: HKCategoryType(.menstrualFlow),
                                              predicate: HKQuery.predicateForObjects(with: Set(ids)))
            return true
        } catch {
            return false
        }
    }

    /// lodo 档位 → HealthKit 原始值(和 `flowLevel` 反过来)。
    private static func healthValue(_ level: CycleFlowLevel) -> Int {
        if #available(iOS 18.0, macOS 15.0, *) {
            let value: HKCategoryValueVaginalBleeding
            switch level {
            case .none: value = .none
            case .light: value = .light
            case .medium: value = .medium
            case .heavy: value = .heavy
            case .unspecified: value = .unspecified
            }
            return value.rawValue
        } else {
            let value: HKCategoryValueMenstrualFlow
            switch level {
            case .none: value = .none
            case .light: value = .light
            case .medium: value = .medium
            case .heavy: value = .heavy
            case .unspecified: value = .unspecified
            }
            return value.rawValue
        }
    }

    /// HealthKit 档位 → lodo 档位。iOS 18 起叫 HKCategoryValueVaginalBleeding,之前是
    /// HKCategoryValueMenstrualFlow,两者原始值相同;按枚举逐个对,不比大小。认不出的当「有出血没分档」。
    private static func flowLevel(_ value: Int) -> CycleFlowLevel {
        if #available(iOS 18.0, macOS 15.0, *) {
            switch HKCategoryValueVaginalBleeding(rawValue: value) {
            case .none?: return .none
            case .light?: return .light
            case .medium?: return .medium
            case .heavy?: return .heavy
            default: return .unspecified
            }
        } else {
            switch HKCategoryValueMenstrualFlow(rawValue: value) {
            case .none?: return .none
            case .light?: return .light
            case .medium?: return .medium
            case .heavy?: return .heavy
            default: return .unspecified
            }
        }
    }

    // MARK: - 用药(iOS 26+,只读)

    /// 健康 App「用药」里的一种药。
    struct HealthMedication: Identifiable, Equatable {
        /// `HKMedicationConcept.identifier` 的字符串形式,和 `Medication.healthConceptID` 对。
        let id: String
        let name: String
        let archived: Bool
    }

    /// 健康 App 里的一条服药记录(只取「已服用」「已跳过」两种)。
    struct HealthDoseEvent: Equatable {
        let sampleID: String
        let conceptID: String
        let date: Date
        let taken: Bool
        let quantity: Double?
    }

    /// `HKHealthConceptIdentifier` 没有对外的字符串形式,只遵循 NSSecureCoding——
    /// 归档成 base64 当键(同一个系统上同一种药归档结果一致,足够拿来对上服药记录)。
    @available(iOS 26.0, macOS 26.0, *)
    private static func conceptKey(_ identifier: HKHealthConceptIdentifier) -> String {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)
        return data?.base64EncodedString() ?? ""
    }

    static var medicationsSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return isAvailable }
        return false
    }

    /// 用药是**按药授权**的:系统弹一张单子让用户逐种勾选给不给 lodo 看。
    /// 只读——健康 App 不开放第三方写服药记录(HKMedicationDoseEvent 没有构造器)。
    @discardableResult
    static func requestMedicationAuthorization() async -> Bool {
        guard medicationsSupported else { return false }
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                try await store.requestPerObjectReadAuthorization(
                    for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    static func medications() async -> [HealthMedication] {
        guard medicationsSupported else { return [] }
        if #available(iOS 26.0, macOS 26.0, *) {
            let descriptor = HKUserAnnotatedMedicationQueryDescriptor()
            guard let items = try? await descriptor.result(for: store) else { return [] }
            return items.map { item in
                let nickname = item.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return HealthMedication(
                    id: conceptKey(item.medication.identifier),
                    name: nickname.isEmpty ? item.medication.displayText : nickname,
                    archived: item.isArchived)
            }
        }
        return []
    }

    /// 最近 days 天的服药记录。
    static func doseEvents(days: Int) async -> [HealthDoseEvent] {
        guard medicationsSupported, days > 0 else { return [] }
        if #available(iOS 26.0, macOS 26.0, *) {
            let end = Date()
            guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return [] }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.sample(type: HKObjectType.medicationDoseEventType(), predicate: predicate)],
                sortDescriptors: [])
            guard let samples = try? await descriptor.result(for: store) else { return [] }
            return samples.compactMap { sample -> HealthDoseEvent? in
                guard let event = sample as? HKMedicationDoseEvent else { return nil }
                let taken: Bool
                switch event.logStatus {
                case .taken: taken = true
                case .skipped: taken = false
                default: return nil
                }
                return HealthDoseEvent(sampleID: event.uuid.uuidString,
                                       conceptID: conceptKey(event.medicationConceptIdentifier),
                                       date: event.startDate, taken: taken,
                                       quantity: event.doseQuantity)
            }
        }
        return []
    }
}
