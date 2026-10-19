import SwiftUI
import SwiftData
import LodoCore

// 健康页首页的前两组(2026-10 重新设计,方案与 codex 一起定):首屏先回答"今天记了什么、
// 现在要处理什么、去哪儿记",长期的趋势和档案推进二级页。这里只组合已有的数据和入口,
// 不发新的健康查询或网络请求。

/// 「今天」:体重 / 饮食 / 步数三格摘要,「记体重」「记饮食」两个记录入口,每种药的下一顿
/// (最多两种,带「记录已服用」大按钮)。
struct HealthTodaySection: View {
    /// 健康库里的体重(没开健康分析时为空),和手记合并后取最近一笔。
    let healthWeights: [HealthDailyPoint]
    /// 今天的步数:只有健康库序列的最后一点就是今天时才有(旧数据不冒充今天)。
    let todaySteps: Double?
    let healthEnabled: Bool
    let medicationVisible: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: [SortDescriptor(\WeightRecord.date)]) private var records: [WeightRecord]
    @Query(sort: [SortDescriptor(\FoodRecord.date, order: .reverse)]) private var foods: [FoodRecord]
    @Query(sort: [SortDescriptor(\Medication.createdAt)]) private var meds: [Medication]
    @Query(sort: [SortDescriptor(\MedicationDose.takenAt, order: .reverse)]) private var doses: [MedicationDose]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    @State private var now = Date()
    @State private var addingWeight = false
    @State private var addingFood = false
    @State private var addingMedication = false
    /// 刚在这里记掉的那一顿(药品 + 原定时刻,只留最近一顿,首页不越拉越长):记完不马上
    /// 消失,留在原位显示「已服用」,下面接着给这种药的下一顿。跨 0 点时清掉。
    @State private var loggedHere: Set<String> = []

    /// 截图参数 --demo-health-records-scroll 滚到这一组。
    static let anchor = "healthTodayAnchor"
    /// 首页最多摆几种药的下一顿,其余进「用药管理」。
    private static let medicationLimit = 2

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }
    private var weights: [WeightEntry] { WeightPlan.merge(records: records.map(\.entry), health: healthWeights) }
    private var todayFoods: [FoodRecord] { foods.filter { Calendar.current.isDate($0.date, inSameDayAs: now) } }
    private var activeMeds: [Medication] { meds.filter { !$0.archived } }
    private var slots: [MedicationPlan.Slot] {
        MedicationPlan.todaySlots(activeMeds.map(\.entry), doses: doses.map(\.entry), now: now)
    }

    /// 每种药今天还没记的那一顿,到点没吃的排前面,再按时间。
    private var nextSlots: [MedicationPlan.Slot] {
        let ids = Array(NSOrderedSet(array: slots.map(\.medicationID))) as? [UUID] ?? []
        return ids.compactMap { MedicationPlan.nextUnrecordedSlot(of: $0, in: slots) }
            .sorted { lhs, rhs in
                let ld = lhs.state == .due, rd = rhs.state == .due
                return ld != rd ? ld : lhs.time < rhs.time
            }
    }

    private var openSlotCount: Int {
        slots.filter { $0.state == .due || $0.state == .upcoming }.count
    }

    var body: some View {
        Section {
            summary
                .id(Self.anchor)
            recordButtons
            if medicationVisible {
                medicationRows
            }
        } header: {
            Text("今天 · \(now.formatted(.dateTime.month().day().locale(locale)))")
                // sheet 挂在标题行上:挂在 Section 上会分摊到每一行。
                .sheet(isPresented: $addingWeight) { WeightRecordEditView(record: nil, defaults: weights) }
                .sheet(isPresented: $addingFood) { FoodRecordComposeView() }
                .sheet(isPresented: $addingMedication) { MedicationEditView(medication: nil) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { now = Date() }
                }
                // 一直开在前台跨了 0 点:「今天」、摘要和用药跟着换到新的一天。
                .task(id: Calendar.current.startOfDay(for: now)) {
                    let calendar = Calendar.current
                    guard let midnight = calendar.date(byAdding: .day, value: 1,
                                                       to: calendar.startOfDay(for: now)) else { return }
                    try? await Task.sleep(for: .seconds(max(1, midnight.timeIntervalSinceNow + 1)))
                    guard !Task.isCancelled else { return }
                    now = Date()
                    loggedHere = []
                }
        }
    }

    // MARK: - 摘要

    private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            weightStat
            foodStat
            if let todaySteps {
                stat(title: "步数", value: todaySteps.formatted(.number.precision(.fractionLength(0)).locale(locale)),
                     detail: String(localized: "今天", bundle: .appLanguage(), locale: locale))
            }
        }
        .padding(.vertical, 4)
    }

    /// 今天记过就是今天的;没有就报最近一笔并写明哪天;一笔都没有写「尚未记录」。
    private var weightStat: some View {
        let latest = WeightPlan.latestWeight(weights)
        let detail: String? = latest.map { entry in
            Calendar.current.isDate(entry.date, inSameDayAs: now)
                ? String(localized: "今天已记录", bundle: .appLanguage(), locale: locale)
                : entry.date.formatted(.dateTime.month().day().locale(locale))
        }
        return stat(title: "体重",
                    value: latest?.weightKg.map {
                        String(localized: "\(WeightPlan.format($0)) 公斤", bundle: .appLanguage(), locale: locale)
                    },
                    detail: detail)
    }

    /// 只合计已经估算出来的;还没估算的另报条数,不拿 0 冒充摄入。
    private var foodStat: some View {
        let estimated = todayFoods.filter(\.estimated)
        let pending = todayFoods.count - estimated.count
        let calories = estimated.reduce(0) { $0 + $1.nutrition.calories }
        let bundle = Bundle.appLanguage()
        let value: String? = estimated.isEmpty
            ? (pending > 0 ? String(localized: "\(pending) 条", bundle: bundle, locale: locale) : nil)
            : String(localized: "\(Int(calories.rounded())) 千卡", bundle: bundle, locale: locale)
        let detail: String? = if estimated.isEmpty {
            pending > 0 ? String(localized: "待估算", bundle: bundle, locale: locale) : nil
        } else if pending > 0 {
            String(localized: "\(pending) 条未估算", bundle: bundle, locale: locale)
        } else {
            String(localized: "\(estimated.count) 条记录", bundle: bundle, locale: locale)
        }
        return stat(title: "饮食", value: value, detail: detail)
    }

    private func stat(title: LocalizedStringKey, value: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let value {
                Text(verbatim: value)
                    .font(.title3.weight(.semibold).monospacedDigit())
            } else {
                Text("尚未记录")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 记录入口

    private var recordButtons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button {
                addingWeight = true
            } label: {
                Label("记体重", systemImage: "scalemass")
                    .frame(maxWidth: .infinity)
            }
            Button {
                addingFood = true
            } label: {
                Label("记饮食", systemImage: "fork.knife")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - 用药

    @ViewBuilder
    private var medicationRows: some View {
        if meds.isEmpty {
            HStack {
                Label("尚未添加药品", systemImage: "pills")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("添加药品") { addingMedication = true }
                    .buttonStyle(.borderless)
            }
        } else if activeMeds.isEmpty {
            Label("暂无正在使用的药品", systemImage: "pills")
                .foregroundStyle(.secondary)
        } else if slots.isEmpty {
            // 有在用的药,但今天都不用按点吃(按需药、今天不是服药日)。
            Label("今天没有计划用药", systemImage: "pills")
                .foregroundStyle(.secondary)
        } else {
            let next = Array(nextSlots.prefix(Self.medicationLimit))
            let kept = slots.filter { loggedHere.contains($0.stableID) }
            let shown = (kept + next.filter { !loggedHere.contains($0.stableID) })
                .sorted { ($0.time, $0.name) < ($1.time, $1.name) }
            if next.isEmpty {
                Label("今天的计划用药都记过了", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.stableID) { slot in
                MedicationSlotRow(slot: slot, medication: meds.first { $0.uuid == slot.medicationID },
                                  showsButton: next.contains(slot), locale: locale,
                                  onRecorded: { loggedHere = [$0.stableID] })
            }
            let remaining = openSlotCount - next.count
            if remaining > 0 {
                NavigationLink {
                    MedicationManagementView(healthEnabled: healthEnabled)
                } label: {
                    Text("今天还有 \(remaining) 顿")
                }
            }
        }
        // 有药但今天都不用吃(按需药、今天不是服药日):这里不占地方,「用药管理」里看。
    }
}

/// 「健康管理」:体重与饮食、用药管理两个入口(经期是下面单独一组的精简版)。
struct HealthManageSection: View {
    let healthWeights: [HealthDailyPoint]
    let healthSummary: String?
    let todayActiveEnergy: Double?
    let healthEnabled: Bool
    let medicationVisible: Bool
    /// 经期记录开着:精简的经期几行并在这一组里(不再单独成一组)。
    let showsCycle: Bool
    /// 下拉刷新时 +1,经期跟着重读健康 App。
    let refreshToken: Int

    @Query(sort: [SortDescriptor(\WeightRecord.date)]) private var records: [WeightRecord]
    @Query(sort: [SortDescriptor(\Medication.createdAt)]) private var meds: [Medication]
    @AppStorage(AppSettings.weightGoalKey) private var goalRaw = ""

    var body: some View {
        Section {
            NavigationLink {
                WeightManagementView(healthWeights: healthWeights, healthSummary: healthSummary,
                                     todayActiveEnergy: todayActiveEnergy)
            } label: {
                row(title: "体重与饮食", systemImage: "scalemass", detail: weightDetail)
            }
            if medicationVisible {
                NavigationLink {
                    MedicationManagementView(healthEnabled: healthEnabled)
                } label: {
                    row(title: "用药管理", systemImage: "pills", detail: medicationDetail)
                }
            }
            if showsCycle {
                CycleCompactRows(healthEnabled: healthEnabled)
            }
        } header: {
            Text("健康管理")
        }
    }

    private var weightDetail: String {
        let bundle = Bundle.appLanguage()
        let entries = WeightPlan.merge(records: records.map(\.entry), health: healthWeights)
        var parts: [String] = []
        if let weight = WeightPlan.latestWeight(entries)?.weightKg {
            parts.append(String(localized: "最近 \(WeightPlan.format(weight)) 公斤", bundle: bundle))
        }
        if let target = WeightGoal.decode(goalRaw).targetWeightKg {
            parts.append(String(localized: "目标 \(WeightPlan.format(target)) 公斤", bundle: bundle))
        }
        return parts.isEmpty
            ? String(localized: "还没有体重记录", bundle: bundle)
            : parts.joined(separator: " · ")
    }

    private var medicationDetail: String {
        let bundle = Bundle.appLanguage()
        let active = meds.filter { !$0.archived }.count
        if meds.isEmpty { return String(localized: "还没有添加药品", bundle: bundle) }
        if active == 0 { return String(localized: "暂无正在使用的药品", bundle: bundle) }
        return String(localized: "\(active) 种在用", bundle: bundle)
    }

    private func row(title: LocalizedStringKey, systemImage: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
