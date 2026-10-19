import SwiftUI
import SwiftData
import Charts
import LodoCore

// 健康页「体重管理」一组:目标体重/体脂率、手记体重、趋势、今日饮食(文字描述 → AI 估算营养)、
// AI 简短建议 + 饮食安排(每餐点一下建成任务)。纯计算在 LodoCore/WeightPlan.swift、Nutrition.swift。
//
// 和健康开关无关:手记的体重、饮食 Mac 上也能用;开了健康分析时再把健康库里的体重和
// 今天的活动能量补进来。饮食安排**点了才生成**(和 AI 健康分析默认收起同一个口径),
// 发给 AI 的只有汇总:体重/目标摘要、健康库汇总、今天的营养合计——不发每顿饭的原文
// (单条营养估算那一次例外,它本来就要看描述)。

struct WeightSection: View {
    /// 健康库里的体重(没开健康分析时为空)。
    let healthWeights: [HealthDailyPoint]
    /// 健康库的汇总(`HealthReport.promptSummary()`),没开健康分析时为 nil。
    let healthSummary: String?
    /// 今天的活动能量(千卡),来自健康库(多半是 Apple Watch 记的);没开健康分析为 nil。
    let todayActiveEnergy: Double?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: [SortDescriptor(\WeightRecord.date)]) private var records: [WeightRecord]
    @Query(sort: [SortDescriptor(\FoodRecord.date, order: .reverse)]) private var foods: [FoodRecord]
    @AppStorage(AppSettings.weightGoalKey) private var goalRaw = ""

    @State private var foodText = ""
    @State private var foodSaveFailed = false
    @State private var openFood: FoodRecord?
    @FocusState private var foodFocused: Bool

    @State private var plan: WeightDietPlan?
    @State private var loadingPlan = false
    @State private var planFailed = false
    /// 每发一次饮食安排请求 +1;只有最新那次的结果能落地(手动刷新连点、改目标时不乱序覆盖)。
    @State private var planGeneration = 0
    @State private var planTask: Task<Void, Never>?
    @State private var planExpanded = true
    /// 页面上的"现在":回前台时刷新,跨 0 点 / 晚上 8 点后「今日 / 明日」跟着变。
    @State private var now = Date()

    @State private var addingRecord = false
    @State private var editingGoal = false
    @State private var chartMetric: Metric = .weight

    enum Metric: Hashable { case weight, bodyFat }

    /// 首页最多预览几条今天的饮食记录,其余进「饮食记录」。
    private static let todayPreviewLimit = 3
    private static let planKey = "weightDietPlan"
    /// 「今日饮食」那一行的滚动锚点(DEBUG 截图参数 --demo-weight-scroll 用)。
    static let foodAnchor = "weightFoodAnchor"

    private var goal: WeightGoal { WeightGoal.decode(goalRaw) }
    private var entries: [WeightEntry] {
        WeightPlan.merge(records: records.map(\.entry), health: healthWeights)
    }
    private var summary: String? { WeightPlan.promptSummary(entries: entries, goal: goal, now: now) }
    private var isEmpty: Bool { entries.isEmpty && goal.isEmpty }

    /// 晚上 8 点以后给明天排(今天的几顿已经吃完了)。
    private var planDay: (day: Date, isToday: Bool) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if calendar.component(.hour, from: now) >= 20 {
            return (calendar.date(byAdding: .day, value: 1, to: today) ?? today, false)
        }
        return (today, true)
    }

    var body: some View {
        Section {
            if isEmpty {
                introRow
            } else {
                overviewRow
                chartRow
            }
            // 记饮食不依赖体重目标:没设目标也能先记吃了什么。
            foodRows
            if !isEmpty {
                aiRows
                NavigationLink {
                    WeightRecordListView(healthWeights: healthWeights)
                } label: {
                    HStack {
                        Text("全部体重记录")
                        Spacer()
                        Text("\(entries.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            HStack(spacing: 16) {
                Text("体重管理")
                Spacer()
                if !isEmpty {
                    Button { addingRecord = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("记一笔")
                    Button { editingGoal = true } label: { Image(systemName: "target") }
                        .accessibilityLabel("目标")
                }
            }
            // sheet/task 挂在标题行上:挂在 Section 上会分摊到每一行。
            .sheet(isPresented: $addingRecord) { WeightRecordEditView(record: nil, defaults: entries) }
            .sheet(isPresented: $editingGoal) { WeightGoalEditView() }
            .sheet(item: $openFood) { FoodRecordDetailView(record: $0) }
            .task {
                #if DEBUG
                if applyDemoIfNeeded() { return }
                #endif
                loadCachedPlan()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                now = Date()
                loadCachedPlan()
            }
        }
    }

    // MARK: - 空态

    private var introRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("记录体重和体脂率", systemImage: "scalemass")
                .font(.body.weight(.medium))
            Text("设好目标体重和体脂率后,lodo 会画出变化趋势;AI 可以给一句建议和一份饮食安排,每一餐都能一键加进任务。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("设置目标") { editingGoal = true }
                    .buttonStyle(.borderedProminent)
                Button("记一笔") { addingRecord = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 当前 / 目标

    private var overviewRow: some View {
        let latest = WeightPlan.latestWeight(entries)
        let fat = WeightPlan.latestBodyFat(entries)
        let target = goal.targetWeightKg
        let remaining = WeightPlan.remaining(current: latest?.weightKg, target: target)
        let progress = WeightPlan.progress(start: WeightPlan.startWeight(entries),
                                           current: latest?.weightKg, target: target)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let weight = latest?.weightKg {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: WeightPlan.format(weight))
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("公斤")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("还没记体重")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let date = latest?.date {
                        Text(date.formatted(.dateTime.month().day().locale(AppSettings.language.locale)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let target {
                        Text("目标 \(WeightPlan.format(target)) 公斤")
                            .font(.subheadline.weight(.medium))
                        if let remaining {
                            remainingText(remaining)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("设置目标体重") { editingGoal = true }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if let progress {
                ProgressView(value: progress)
                    .accessibilityLabel("目标进度")
            }
            // 体脂率 / BMI / 去脂体重,一行三格。
            HStack(alignment: .top, spacing: 0) {
                stat(title: "体脂率",
                     value: fat?.bodyFatPercent.map { "\(WeightPlan.format($0))%" },
                     detail: goal.targetBodyFatPercent.map {
                         String(localized: "目标 \(WeightPlan.format($0) + "%")", bundle: .appLanguage())
                     })
                stat(title: "BMI",
                     value: WeightPlan.bmi(weightKg: latest?.weightKg, heightCm: goal.heightCm)
                        .map { WeightPlan.format($0) },
                     detail: WeightPlan.bmi(weightKg: latest?.weightKg, heightCm: goal.heightCm)
                        .map { bandTitle(WeightPlan.band($0)) }
                        ?? (goal.heightCm == nil ? String(localized: "填身高后计算", bundle: .appLanguage()) : nil))
                stat(title: "去脂体重",
                     value: WeightPlan.composition(weightKg: latest?.weightKg,
                                                   bodyFatPercent: fat?.bodyFatPercent)
                        .map { String(localized: "\(WeightPlan.format($0.lean)) 公斤", bundle: .appLanguage()) },
                     detail: WeightPlan.composition(weightKg: latest?.weightKg,
                                                    bodyFatPercent: fat?.bodyFatPercent)
                        .map { String(localized: "脂肪 \(WeightPlan.format($0.fat)) 公斤", bundle: .appLanguage()) })
            }
        }
        .padding(.vertical, 4)
    }

    private func remainingText(_ remaining: Double) -> Text {
        if abs(remaining) < 0.05 { return Text("已达到目标") }
        let amount = WeightPlan.format(abs(remaining))
        return remaining > 0 ? Text("还要减 \(amount) 公斤") : Text("还要增 \(amount) 公斤")
    }

    private func stat(title: LocalizedStringKey, value: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: value ?? "—")
                .font(.body.weight(.medium).monospacedDigit())
            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bandTitle(_ band: WeightPlan.BMIBand) -> String {
        switch band {
        case .under: return String(localized: "偏瘦", bundle: .appLanguage())
        case .normal: return String(localized: "正常", bundle: .appLanguage())
        case .over: return String(localized: "超重", bundle: .appLanguage())
        case .obese: return String(localized: "肥胖", bundle: .appLanguage())
        }
    }

    // MARK: - 趋势

    /// 最近 90 天。体脂率有记录时才给切换;切换条放在点数判断外面,
    /// 切到只有一笔的指标也能切回来。
    @ViewBuilder
    private var chartRow: some View {
        let from = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let recent = entries.filter { $0.date >= from }
        let hasFat = recent.contains { $0.bodyFatPercent != nil }
        let hasWeight = recent.contains { $0.weightKg != nil }
        let metric: Metric = !hasFat ? .weight : (!hasWeight ? .bodyFat : chartMetric)
        let points: [(Date, Double)] = recent.compactMap { entry in
            let value = metric == .weight ? entry.weightKg : entry.bodyFatPercent
            return value.map { (entry.date, $0) }
        }
        let target = metric == .weight ? goal.targetWeightKg : goal.targetBodyFatPercent
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if hasFat && hasWeight {
                    Picker("指标", selection: $chartMetric) {
                        Text("体重").tag(Metric.weight)
                        Text("体脂率").tag(Metric.bodyFat)
                    }
                    .segmentedPickerStyle()
                    .labelsHidden()
                }
                if points.count >= 2 {
                    Chart {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("日期", point.0, unit: .day), y: .value("数值", point.1))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("日期", point.0, unit: .day), y: .value("数值", point.1))
                                .symbolSize(18)
                        }
                        if let target {
                            RuleMark(y: .value("目标", target))
                                .foregroundStyle(LodoColor.positive.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .leading) {
                                    Text("目标")
                                        .font(.caption2)
                                        .foregroundStyle(LodoColor.positive)
                                }
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day()
                                .locale(AppSettings.language.locale))
                        }
                    }
                    .frame(height: 150)
                    .accessibilityLabel(metric == .weight ? Text("体重趋势") : Text("体脂率趋势"))
                } else {
                    Text("再记一笔就能看到趋势。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - AI 建议与饮食安排

    /// 标题按这份安排**自己的日子**写,不按当前时间猜:换了天还摆着的旧安排写明日期、不让加任务。
    private func planTitle(_ plan: WeightDietPlan) -> Text {
        let calendar = Calendar.current
        if calendar.isDate(plan.day, inSameDayAs: now) { return Text("今日饮食安排") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(plan.day, inSameDayAs: tomorrow) { return Text("明日饮食安排") }
        let day = plan.day.formatted(.dateTime.month().day().locale(AppSettings.language.locale))
        return Text("\(day)的饮食安排")
    }

    /// 已经过去的日子的安排:只看,不能再加成任务。
    private func isStale(_ plan: WeightDietPlan) -> Bool {
        plan.day < Calendar.current.startOfDay(for: now)
    }

    @ViewBuilder
    private var aiRows: some View {
        if !DeepSeekClient.isConfigured {
            Text("配置 AI 服务后,这里可以生成建议和饮食安排。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let plan, !isStale(plan) || loadingPlan || planFailed {
            if !plan.advice.isEmpty {
                Label(plan.advice, systemImage: "sparkles")
                    .font(.body)
            }
            if !plan.meals.isEmpty {
                DisclosureGroup(isExpanded: $planExpanded) {
                    ForEach(plan.meals) { meal in
                        mealRow(meal, in: plan)
                    }
                } label: {
                    planHeader(plan)
                }
            }
            if planFailed {
                retryRow("这次没能刷新,上面是之前的安排。")
            }
        } else if loadingPlan {
            HStack {
                ProgressView().controlSize(.small)
                Text("AI 正在安排饮食…").foregroundStyle(.secondary)
            }
        } else if planFailed {
            retryRow("这次没能生成饮食安排,可能是网络或 AI 服务暂时出错。")
        } else {
            Button {
                generatePlan()
            } label: {
                Label(planDay.isToday ? "生成今日建议与饮食安排" : "生成明日建议与饮食安排",
                      systemImage: "sparkles")
            }
            .buttonStyle(.borderless)
            .disabled(summary == nil)
        }
    }

    private func planHeader(_ plan: WeightDietPlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                planTitle(plan)
                    .font(.body.weight(.semibold))
                if let total = plan.totalCalories {
                    Text("约 \(total) 千卡")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if loadingPlan {
                ProgressView().controlSize(.small)
            } else {
                Button { generatePlan() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("重新生成")
            }
            if !isStale(plan), plan.meals.contains(where: { linkedTask(for: $0) == nil }) {
                Button("全部加入任务") { addAll() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
    }

    /// 点右边的圆圈 = 建成任务 / 再点一下删掉那条任务。已加入的状态按**真实任务**显示
    /// (时间、是否完成);任务在别处被删了就当没加过。
    private func mealRow(_ meal: WeightDietPlan.Meal, in plan: WeightDietPlan) -> some View {
        let task = linkedTask(for: meal)
        let stale = isStale(plan)
        return Button {
            toggleTask(for: meal)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: meal.time)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: meal.meal)
                            .font(.body.weight(.medium))
                        if let calories = meal.calories {
                            Text("\(calories) 千卡")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(verbatim: meal.food)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    if let task {
                        Group {
                            if task.status == .done {
                                Text("任务已完成")
                            } else {
                                Text("已加入任务 · \(TaskItem.format(task.remindAt))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(LodoColor.positive)
                    }
                }
                Spacer(minLength: 4)
                if task != nil || !stale {
                    Image(systemName: task != nil ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(task != nil ? AnyShapeStyle(LodoColor.positive) : AnyShapeStyle(.tint))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(stale || task?.status == .done)
        .accessibilityHint(task != nil ? Text("从任务里移除") : Text("加入任务"))
    }

    private func retryRow(_ message: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("重试") { generatePlan() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
        }
    }

    // MARK: - 饮食记录

    private var todayFoods: [FoodRecord] {
        foods.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }
    }

    private var todayIntake: Nutrition {
        todayFoods.reduce(.zero) { $0 + $1.nutrition }
    }

    /// 喂给饮食安排的"今天的营养合计 + 活动消耗"。只发合计和条数,不发每顿饭的原文。
    private var todayFoodSummary: String? {
        FoodPlan.todaySummary(
            estimatedCount: todayFoods.filter(\.estimated).count,
            pendingCount: todayFoods.filter { !$0.estimated }.count,
            intake: todayIntake, activeEnergy: todayActiveEnergy)
    }

    @ViewBuilder
    private var foodRows: some View {
        let estimated = todayFoods.filter(\.estimated).count
        let pending = todayFoods.count - estimated
        VStack(alignment: .leading, spacing: 8) {
            Text("今日饮食")
                .font(.body.weight(.semibold))
            HStack(alignment: .top, spacing: 0) {
                stat(title: "摄入",
                     value: estimated > 0
                        ? String(localized: "\(Int(todayIntake.calories.rounded())) 千卡", bundle: .appLanguage()) : nil,
                     detail: pending > 0
                        ? String(localized: "\(pending) 条未估算", bundle: .appLanguage())
                        : (todayFoods.isEmpty ? nil
                           : String(localized: "\(todayFoods.count) 条记录", bundle: .appLanguage())))
                stat(title: "活动消耗",
                     value: todayActiveEnergy.map {
                         String(localized: "\(Int($0.rounded())) 千卡", bundle: .appLanguage())
                     },
                     detail: todayActiveEnergy == nil
                        ? String(localized: "开启健康分析后读取", bundle: .appLanguage())
                        : String(localized: "来自健康 App", bundle: .appLanguage()))
                stat(title: "蛋白 / 碳水 / 脂肪",
                     value: estimated > 0
                        ? "\(Int(todayIntake.proteinG.rounded())) / \(Int(todayIntake.carbsG.rounded())) / \(Int(todayIntake.fatG.rounded()))"
                        : nil,
                     detail: String(localized: "克", bundle: .appLanguage()))
            }
        }
        .padding(.vertical, 4)
        .id(WeightSection.foodAnchor)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("吃了什么?如:一碗牛肉面加个卤蛋", text: $foodText, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($foodFocused)
                    .submitLabel(.done)
                    .onSubmit(addFood)
                Button(action: addFood) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(foodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("记下")
            }
            if foodSaveFailed {
                Text("没能保存,请再试一次。")
                    .font(.footnote)
                    .foregroundStyle(LodoColor.critical)
            } else if DeepSeekClient.isConfigured {
                Text("这句描述会发给 AI 服务估算热量和营养素。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(todayFoods.prefix(Self.todayPreviewLimit)) { food in
            FoodRecordRow(record: food)
                .contentShape(Rectangle())
                .onTapGesture { openFood = food }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        context.delete(food)
                        try? context.save()
                    }
                }
        }

        if !foods.isEmpty {
            NavigationLink {
                FoodRecordListView()
            } label: {
                HStack {
                    Text("饮食记录")
                    Spacer()
                    Text("\(foods.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// 先落库原文,存成功了再清输入、再去估算(估算失败这一条也留着,可以重试)。
    private func addFood() {
        let text = foodText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let record = FoodRecord(text: text)
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.delete(record)
            foodSaveFailed = true
            return
        }
        foodSaveFailed = false
        foodText = ""
        foodFocused = false
        now = Date()
        Task { await FoodLog.estimate(record, context: context) }
    }

    // MARK: - 建任务

    private func linkedTask(for meal: WeightDietPlan.Meal) -> TaskItem? {
        guard let uuid = meal.taskUUID else { return nil }
        return ((try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.uuid == uuid }))) ?? []).first
    }

    private func toggleTask(for meal: WeightDietPlan.Meal) {
        guard var current = plan, let index = current.meals.firstIndex(where: { $0.id == meal.id }) else { return }
        if let task = linkedTask(for: meal) {
            if task.status == .pending { TaskActions.delete(task, context: context) }
            current.meals[index].taskUUID = nil
        } else {
            guard !isStale(current) else { return }
            current.meals[index].taskUUID = createTask(for: meal, in: current)
            WidgetBridge.sync(context: context)
            CalendarSync.sync(context: context)
        }
        savePlan(current)
    }

    private func addAll() {
        guard var current = plan, !isStale(current) else { return }
        for index in current.meals.indices where linkedTask(for: current.meals[index]) == nil {
            current.meals[index].taskUUID = createTask(for: current.meals[index], in: current)
        }
        WidgetBridge.sync(context: context)
        CalendarSync.sync(context: context)
        savePlan(current)
    }

    private func createTask(for meal: WeightDietPlan.Meal, in plan: WeightDietPlan) -> UUID {
        let parsed = ParsedTask(title: meal.taskTitle, remindAt: plan.remindAt(for: meal, now: Date()),
                                allDay: false, repeatType: .none, repeatDays: [], repeatTimes: [])
        return TaskActions.create(parsed, context: context).uuid
    }

    // MARK: - 加载

    private func savePlan(_ value: WeightDietPlan) {
        plan = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.planKey)
        }
    }

    /// 只读缓存,不发请求:缓存的是最近生成的那一份,过期的日子由 `isStale` 挡住加任务。
    private func loadCachedPlan() {
        guard plan == nil, !loadingPlan else { return }
        plan = UserDefaults.standard.data(forKey: Self.planKey)
            .flatMap { try? JSONDecoder().decode(WeightDietPlan.self, from: $0) }
    }

    /// 用户点了才生成。新的一次会取消还在跑的上一次,并且只有最新那次能写状态。
    private func generatePlan() {
        guard DeepSeekClient.isConfigured, let summary else { return }
        planTask?.cancel()
        planGeneration += 1
        let generation = planGeneration
        now = Date()
        let target = planDay
        let todaySummary = todayFoodSummary
        let health = healthSummary
        let language = MenuStore.targetLanguageName(AppSettings.language)
        loadingPlan = true
        planFailed = false
        planTask = Task {
            let result = await Task.detached { () -> WeightDietPlan? in
                try? await DeepSeekClient.weightPlan(
                    summary: summary, healthSummary: health, todaySummary: todaySummary,
                    day: target.day, isToday: target.isToday, language: language)
            }.value
            guard generation == planGeneration, !Task.isCancelled else { return }
            loadingPlan = false
            guard let result else {
                planFailed = true
                return
            }
            // 重新生成后菜可能全换了:不沿用旧安排的任务关联(那些任务照旧留在任务列表里)。
            savePlan(result)
            planExpanded = true
        }
    }
}

#if DEBUG
extension WeightSection {
    /// --demo-weight:塞几笔样板体重 + 目标 + 一份假的饮食安排(不走网络)。
    /// 记录真的写进库(只在库里一笔都没有时),目标只在没设时写。返回 true = 用了样板安排。
    fileprivate func applyDemoIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--demo-weight") else { return false }
        let calendar = Calendar.current
        if records.isEmpty {
            let samples: [(Int, Double, Double?)] = [
                (-42, 78.6, 26.1), (-35, 78.1, nil), (-28, 77.4, 25.4), (-21, 77.0, nil),
                (-14, 76.2, 24.6), (-10, 76.4, nil), (-7, 75.8, 24.1), (-3, 75.3, nil), (0, 75.0, 23.6),
            ]
            for (offset, weight, fat) in samples {
                let date = calendar.date(byAdding: .day, value: offset, to: .now) ?? .now
                context.insert(WeightRecord(date: date, weightKg: weight, bodyFatPercent: fat))
            }
            try? context.save()
        }
        if !foods.contains(where: { calendar.isDateInToday($0.date) }) {
            let breakfast = FoodRecord(date: calendar.date(bySettingHour: 7, minute: 40, second: 0, of: .now) ?? .now,
                                       text: "一杯拿铁 + 全麦面包两片")
            breakfast.apply(NutritionEstimate(items: [
                NutritionItem(name: "拿铁", amount: "大杯", nutrition: Nutrition(calories: 190, proteinG: 10, fatG: 7, carbsG: 19)),
                NutritionItem(name: "全麦面包", amount: "2 片", nutrition: Nutrition(calories: 160, proteinG: 7, fatG: 2, carbsG: 28)),
            ]))
            context.insert(breakfast)
            context.insert(FoodRecord(date: calendar.date(bySettingHour: 12, minute: 15, second: 0, of: .now) ?? .now,
                                      text: "一碗牛肉面加个卤蛋"))
            try? context.save()
        }
        if goalRaw.isEmpty {
            goalRaw = WeightGoal(heightCm: 175, targetWeightKg: 70, targetBodyFatPercent: 18).encoded
        }
        plan = WeightDietPlan(advice: "这周掉了 0.8 公斤,节奏正好;晚饭主食减半,饭后快走 20 分钟。", meals: [
            .init(meal: "早餐", time: "07:30", food: "燕麦 50 克 + 牛奶 250 毫升 + 两个水煮蛋", calories: 420),
            .init(meal: "午餐", time: "12:00", food: "糙米饭半碗 + 清炒西兰花 + 鸡胸肉 150 克", calories: 560),
            .init(meal: "加餐", time: "15:30", food: "一个苹果 + 一小把坚果", calories: 180),
            .init(meal: "晚餐", time: "18:30", food: "清蒸鱼 + 凉拌黄瓜 + 一碗紫菜蛋花汤", calories: 450),
        ], day: planDay.day)
        return true
    }
}
#endif

// MARK: - 全部体重记录

struct WeightRecordListView: View {
    let healthWeights: [HealthDailyPoint]

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\WeightRecord.date, order: .reverse)]) private var records: [WeightRecord]
    @State private var editing: WeightRecord?
    @State private var adding = false

    private var entries: [WeightEntry] {
        WeightPlan.merge(records: records.map(\.entry), health: healthWeights).reversed()
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "scalemass")
                    .emptyStateFill()
            }
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .pageTitle("体重记录")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("记一笔")
            }
        }
        .sheet(isPresented: $adding) {
            WeightRecordEditView(record: nil, defaults: WeightPlan.merge(records: records.map(\.entry).reversed(), health: healthWeights))
        }
        .sheet(item: $editing) { WeightRecordEditView(record: $0, defaults: []) }
    }

    @ViewBuilder
    private func row(_ entry: WeightEntry) -> some View {
        let content = HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.year().month().day().locale(AppSettings.language.locale)))
                    .font(.body.weight(.medium))
                if entry.fromHealth {
                    Text("来自健康")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let note = records.first(where: { $0.uuid == entry.id })?.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let weight = entry.weightKg {
                    Text("\(WeightPlan.format(weight)) 公斤")
                        .font(.body.monospacedDigit())
                }
                if let fat = entry.bodyFatPercent {
                    Text("体脂率 \(WeightPlan.format(fat) + "%")")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        if entry.fromHealth {
            content
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture { editing = records.first { $0.uuid == entry.id } }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        if let record = records.first(where: { $0.uuid == entry.id }) {
                            context.delete(record)
                            try? context.save()
                        }
                    }
                }
        }
    }
}

// MARK: - 饮食记录

/// 估算一条饮食记录(新记的、改了描述的、失败后点重试的共用)。正在估算的 uuid 记在
/// `inFlight`,行上据此显示"估算中",同一条不会并发请求两次。
///
/// **结果只认发请求时的那句描述**:估算期间用户改了描述,旧结果作废,接着按新描述再估一次
/// ——不然会出现新描述配旧营养值、还标成已估算。
@MainActor
@Observable
final class FoodLog {
    static let shared = FoodLog()
    private(set) var inFlight: Set<UUID> = []
    private(set) var failed: Set<UUID> = []

    static func estimate(_ record: FoodRecord, context: ModelContext) async {
        let log = shared
        let uuid = record.uuid
        guard DeepSeekClient.isConfigured else {
            log.failed.insert(uuid)
            return
        }
        // 已经在估了:那一轮结束时会发现描述变了、自己接着估最新的。
        guard !log.inFlight.contains(uuid) else { return }
        log.inFlight.insert(uuid)
        log.failed.remove(uuid)
        defer { log.inFlight.remove(uuid) }
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            let text = record.text
            do {
                let estimate = try await DeepSeekClient.estimateNutrition(text: text)
                // 估算期间这条可能被删了。
                guard !record.isDeleted else { return }
                // 描述改过了:这份结果对不上,按新描述再来。
                guard record.text == text else { continue }
                record.apply(estimate)
                try? context.save()
                return
            } catch {
                guard !record.isDeleted else { return }
                if record.text != text { continue }
                log.failed.insert(uuid)
                return
            }
        }
    }
}

struct FoodRecordRow: View {
    let record: FoodRecord
    var showsDate = false
    @Environment(\.modelContext) private var context

    var body: some View {
        let log = FoodLog.shared
        HStack(alignment: .top, spacing: 12) {
            Text(record.date.formatted(showsDate
                    ? .dateTime.month().day().hour().minute().locale(AppSettings.language.locale)
                    : .dateTime.hour().minute().locale(AppSettings.language.locale)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                if record.estimated {
                    Text("蛋白 \(Int(record.proteinG.rounded())) 克 · 碳水 \(Int(record.carbsG.rounded())) 克 · 脂肪 \(Int(record.fatG.rounded())) 克")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if record.estimated {
                Text("\(Int(record.calories.rounded())) 千卡")
                    .font(.subheadline.weight(.medium).monospacedDigit())
            } else if log.inFlight.contains(record.uuid) {
                ProgressView().controlSize(.small)
            } else {
                Button("估算") { Task { await FoodLog.estimate(record, context: context) } }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .accessibilityHint(log.failed.contains(record.uuid) ? Text("上次没估算出来") : Text(""))
            }
        }
    }
}

/// 全部饮食记录,按天分组,每天标出合计。
struct FoodRecordListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\FoodRecord.date, order: .reverse)]) private var foods: [FoodRecord]
    @State private var open: FoodRecord?

    private var days: [(day: Date, records: [FoodRecord])] {
        let calendar = Calendar.current
        var result: [(Date, [FoodRecord])] = []
        for food in foods {
            let day = calendar.startOfDay(for: food.date)
            if let last = result.last, last.0 == day {
                result[result.count - 1].1.append(food)
            } else {
                result.append((day, [food]))
            }
        }
        return result
    }

    var body: some View {
        List {
            if foods.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "fork.knife")
                    .emptyStateFill()
            }
            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.records) { food in
                        FoodRecordRow(record: food)
                            .contentShape(Rectangle())
                            .onTapGesture { open = food }
                            .swipeActions(edge: .trailing) {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    context.delete(food)
                                    try? context.save()
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(group.day.formatted(.dateTime.month().day().weekday().locale(AppSettings.language.locale)))
                        Spacer()
                        let total = group.records.reduce(Nutrition.zero) { $0 + $1.nutrition }
                        if group.records.contains(where: \.estimated) {
                            Text("\(Int(total.calories.rounded())) 千卡")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .pageTitle("饮食记录")
        .sheet(item: $open) { FoodRecordDetailView(record: $0) }
    }
}

/// 一条饮食记录:逐项估算、改时间/描述(改了描述重新估算)、删除。
struct FoodRecordDetailView: View {
    let record: FoodRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("吃了什么", text: $text, axis: .vertical)
                    DatePicker("时间", selection: $date, in: ...Date.now)
                }
                Section {
                    if record.estimated {
                        ForEach(Array(record.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.amount.isEmpty ? item.name : "\(item.name) · \(item.amount)")
                                    Text("蛋白 \(Int(item.nutrition.proteinG.rounded())) 克 · 碳水 \(Int(item.nutrition.carbsG.rounded())) 克 · 脂肪 \(Int(item.nutrition.fatG.rounded())) 克")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Int(item.nutrition.calories.rounded())) 千卡")
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent("合计") {
                            Text("\(Int(record.calories.rounded())) 千卡")
                                .monospacedDigit()
                        }
                    } else if FoodLog.shared.inFlight.contains(record.uuid) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在估算…").foregroundStyle(.secondary)
                        }
                    }
                    Button(record.estimated ? "重新估算" : "估算营养") {
                        commit()
                        Task { await FoodLog.estimate(record, context: context) }
                    }
                    .disabled(FoodLog.shared.inFlight.contains(record.uuid))
                } header: {
                    Text("营养估算")
                } footer: {
                    Text("这句描述会发给 AI 服务,按常见做法和份量估算,仅供参考。")
                }
                Section {
                    Button("删除这条记录", role: .destructive) {
                        context.delete(record)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle("饮食记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let changed = commit()
                        if changed { Task { await FoodLog.estimate(record, context: context) } }
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = record.text
                date = record.date
            }
        }
    }

    /// 写回时间和描述;描述改了返回 true(调用方重新估算)。
    @discardableResult
    private func commit() -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !trimmed.isEmpty && trimmed != record.text
        if changed {
            record.text = trimmed
            record.estimated = false
        }
        record.date = date
        try? context.save()
        return changed
    }
}

// MARK: - 编辑

/// 输入框里的数字:认 "72.5" / "72,5",非法或非正数返回 nil。
private func parseDecimal(_ text: String) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
    return value
}

private func decimalText(_ value: Double?) -> String {
    value.map(WeightPlan.format) ?? ""
}

struct WeightRecordEditView: View {
    let record: WeightRecord?
    /// 新建时用最近一笔预填(称体重的数字天天差不多,改一位就行)。
    let defaults: [WeightEntry]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var weight = ""
    @State private var bodyFat = ""
    @State private var note = ""
    @State private var loaded = false
    @State private var saveFailed = false

    private var weightValue: Double? { parseDecimal(weight) }
    private var bodyFatValue: Double? { parseDecimal(bodyFat).flatMap { $0 < 80 ? $0 : nil } }
    private var weightInvalid: Bool { !weight.isEmpty && (weightValue == nil || weightValue! > 500) }
    private var bodyFatInvalid: Bool { !bodyFat.isEmpty && bodyFatValue == nil }
    private var canSave: Bool {
        (weightValue != nil || bodyFatValue != nil) && !weightInvalid && !bodyFatInvalid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("日期", selection: $date, in: ...Date.now)
                    LabeledContent("体重") {
                        HStack(spacing: 4) {
                            TextField("公斤", text: $weight)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text("公斤").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("体脂率") {
                        HStack(spacing: 4) {
                            TextField("可不填", text: $bodyFat)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text(verbatim: "%").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if saveFailed {
                        Text("没能保存,请再试一次。")
                            .foregroundStyle(LodoColor.critical)
                    } else if weightInvalid || bodyFatInvalid {
                        Text("数字看起来不对,请检查一下。")
                            .foregroundStyle(LodoColor.critical)
                    } else {
                        Text("体重和体脂率至少填一个。")
                    }
                }
                Section("备注") {
                    TextField("比如:早上空腹", text: $note, axis: .vertical)
                }
                if let record {
                    Section {
                        Button("删除这条记录", role: .destructive) {
                            context.delete(record)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle(record == nil ? "记一笔" : "编辑记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let record {
            date = record.date
            weight = decimalText(record.weightKg)
            bodyFat = decimalText(record.bodyFatPercent)
            note = record.note
        } else {
            weight = decimalText(WeightPlan.latestWeight(defaults)?.weightKg)
        }
    }

    private func save() {
        let target = record ?? {
            let created = WeightRecord()
            context.insert(created)
            return created
        }()
        target.date = date
        target.weightKg = weightValue
        target.bodyFatPercent = bodyFatValue
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try context.save()
            dismiss()
        } catch {
            // 存不进去就别关表单假装成功;新建的那条撤回,免得重试时插两条。
            context.rollback()
            saveFailed = true
        }
    }
}

struct WeightGoalEditView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.weightGoalKey) private var goalRaw = ""
    @State private var height = ""
    @State private var targetWeight = ""
    @State private var targetBodyFat = ""
    @State private var loaded = false

    private var goal: WeightGoal {
        WeightGoal(heightCm: parsedHeight, targetWeightKg: parsedWeight, targetBodyFatPercent: parsedBodyFat)
    }
    private var parsedHeight: Double? { parseDecimal(height).flatMap { (50...260).contains($0) ? $0 : nil } }
    private var parsedWeight: Double? { parseDecimal(targetWeight).flatMap { (20...500).contains($0) ? $0 : nil } }
    private var parsedBodyFat: Double? { parseDecimal(targetBodyFat).flatMap { (2..<80).contains($0) ? $0 : nil } }
    /// 填了但不合理(和"没填"分开):不能静默存成"未设置",把原来的目标冲掉。
    private var hasInvalidField: Bool {
        func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return (filled(height) && parsedHeight == nil)
            || (filled(targetWeight) && parsedWeight == nil)
            || (filled(targetBodyFat) && parsedBodyFat == nil)
    }

    /// 按身高给的健康体重范围(BMI 18.5–24),填目标时参考。
    private var healthyRange: (Double, Double)? {
        guard let cm = goal.heightCm else { return nil }
        let m = cm / 100
        return (18.5 * m * m, 23.9 * m * m)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("身高", text: $height, unit: "厘米")
                    field("目标体重", text: $targetWeight, unit: "公斤")
                    field("目标体脂率", text: $targetBodyFat, unit: "%")
                } footer: {
                    if hasInvalidField {
                        Text("身高填 50 到 260 厘米、体重 20 到 500 公斤、体脂率 2 到 80 之间。")
                            .foregroundStyle(LodoColor.critical)
                    } else if let range = healthyRange {
                        Text("按你的身高,BMI 正常范围对应 \(WeightPlan.format(range.0))–\(WeightPlan.format(range.1)) 公斤。")
                    } else {
                        Text("都可以不填。填了身高会计算 BMI,并给出健康体重范围。")
                    }
                }
                if !goal.isEmpty {
                    Section {
                        Button("清除目标", role: .destructive) {
                            goalRaw = ""
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle("体重目标")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        goalRaw = goal.encoded
                        dismiss()
                    }
                    .disabled(hasInvalidField)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let current = WeightGoal.decode(goalRaw)
                height = decimalText(current.heightCm)
                targetWeight = decimalText(current.targetWeightKg)
                targetBodyFat = decimalText(current.targetBodyFatPercent)
            }
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, unit: LocalizedStringKey) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("未设置", text: text)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
