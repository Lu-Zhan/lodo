import Foundation

/// 体重管理的目标(身高、目标体重、目标体脂率)。存本机 UserDefaults(`AppSettings`),
/// 进备份(`BackupPayload.weightGoal`)。全部可选:只设了体重目标也照常用。
public struct WeightGoal: Codable, Equatable, Sendable {
    public var heightCm: Double?
    public var targetWeightKg: Double?
    public var targetBodyFatPercent: Double?

    public init(heightCm: Double? = nil, targetWeightKg: Double? = nil,
                targetBodyFatPercent: Double? = nil) {
        self.heightCm = heightCm
        self.targetWeightKg = targetWeightKg
        self.targetBodyFatPercent = targetBodyFatPercent
    }

    public var isEmpty: Bool { heightCm == nil && targetWeightKg == nil && targetBodyFatPercent == nil }

    /// 存 UserDefaults 的 JSON 串;空目标存空串。
    public var encoded: String {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ raw: String) -> WeightGoal {
        guard let data = raw.data(using: .utf8),
              let goal = try? JSONDecoder().decode(WeightGoal.self, from: data) else { return WeightGoal() }
        return goal
    }
}

/// 一笔体重/体脂率的值快照(手记的 `WeightRecord`,或健康库里某天的体重)。
public struct WeightEntry: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var weightKg: Double?
    public var bodyFatPercent: Double?
    /// true = 来自健康库(只读,不能在 lodo 里改/删)。
    public var fromHealth: Bool

    public init(id: UUID = UUID(), date: Date, weightKg: Double?, bodyFatPercent: Double?,
                fromHealth: Bool = false) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.fromHealth = fromHealth
    }
}

/// 体重管理的纯计算:合并、当前值、进度、BMI、喂给 AI 的摘要。
public enum WeightPlan {
    /// 手记 + 健康库合并,按时间升序。健康库只补**手记没有的日子**(同一天以手记为准)。
    public static func merge(records: [WeightEntry], health: [HealthDailyPoint],
                             calendar: Calendar = .current) -> [WeightEntry] {
        let recordedDays = Set(records.filter { $0.weightKg != nil }
            .map { calendar.startOfDay(for: $0.date) })
        let fromHealth = health
            .filter { !recordedDays.contains(calendar.startOfDay(for: $0.date)) && $0.value > 0 }
            .map { WeightEntry(date: $0.date, weightKg: $0.value, bodyFatPercent: nil, fromHealth: true) }
        return (records + fromHealth).sorted { $0.date < $1.date }
    }

    /// 最近一笔体重。
    public static func latestWeight(_ entries: [WeightEntry]) -> WeightEntry? {
        entries.last { $0.weightKg != nil }
    }

    /// 最近一笔体脂率。
    public static func latestBodyFat(_ entries: [WeightEntry]) -> WeightEntry? {
        entries.last { $0.bodyFatPercent != nil }
    }

    /// 进度的起点:最早那笔体重。
    public static func startWeight(_ entries: [WeightEntry]) -> Double? {
        entries.first { $0.weightKg != nil }?.weightKg
    }

    /// 离目标还差多少(当前 − 目标,正数 = 还要减)。
    public static func remaining(current: Double?, target: Double?) -> Double? {
        guard let current, let target else { return nil }
        return current - target
    }

    /// 从起点走向目标的完成度,0…1。起点就等于目标、或者走反了时按 0 算;
    /// 已经达到/越过目标按 1。增重目标同样适用(方向由起点和目标决定)。
    public static func progress(start: Double?, current: Double?, target: Double?) -> Double? {
        guard let start, let current, let target else { return nil }
        let total = target - start
        guard abs(total) > 0.05 else { return abs(current - target) <= 0.05 ? 1 : 0 }
        return min(max((current - start) / total, 0), 1)
    }

    public static func bmi(weightKg: Double?, heightCm: Double?) -> Double? {
        guard let weightKg, let heightCm, heightCm > 50 else { return nil }
        let meters = heightCm / 100
        return weightKg / (meters * meters)
    }

    /// 中国成人 BMI 分档(卫健委口径):<18.5 偏瘦、<24 正常、<28 超重、≥28 肥胖。
    public enum BMIBand: String, Sendable {
        case under, normal, over, obese
    }

    public static func band(_ bmi: Double) -> BMIBand {
        switch bmi {
        case ..<18.5: return .under
        case ..<24: return .normal
        case ..<28: return .over
        default: return .obese
        }
    }

    /// 最近 `days` 天的体重变化(最后一笔 − 窗口里最早一笔);窗口里不到两笔返回 nil。
    public static func change(_ entries: [WeightEntry], days: Int, now: Date = .now,
                              calendar: Calendar = .current) -> Double? {
        guard let from = calendar.date(byAdding: .day, value: -days, to: now) else { return nil }
        let window = entries.filter { $0.weightKg != nil && $0.date >= from && $0.date <= now }
        guard window.count >= 2, let first = window.first?.weightKg,
              let last = window.last?.weightKg else { return nil }
        return last - first
    }

    /// 脂肪重量 / 去脂体重(公斤);缺体重或体脂率返回 nil。
    public static func composition(weightKg: Double?, bodyFatPercent: Double?)
        -> (fat: Double, lean: Double)? {
        guard let weightKg, let bodyFatPercent, bodyFatPercent > 0, bodyFatPercent < 80 else { return nil }
        let fat = weightKg * bodyFatPercent / 100
        return (fat, weightKg - fat)
    }

    /// 喂给 AI 的摘要(中文,模型可见格式,不随应用语言变)。没有任何数据也没有目标时返回 nil。
    public static func promptSummary(entries: [WeightEntry], goal: WeightGoal, now: Date = .now,
                                     calendar: Calendar = .current) -> String? {
        var lines: [String] = []
        if let height = goal.heightCm { lines.append("身高 \(format(height)) 厘米") }
        if let latest = latestWeight(entries), let weight = latest.weightKg {
            lines.append("当前体重 \(format(weight)) 公斤(\(dayString(latest.date, calendar: calendar)))")
            if let bmi = bmi(weightKg: weight, heightCm: goal.heightCm) {
                lines.append("BMI \(format(bmi))")
            }
        }
        if let target = goal.targetWeightKg { lines.append("目标体重 \(format(target)) 公斤") }
        if let latest = latestBodyFat(entries), let fat = latest.bodyFatPercent {
            lines.append("当前体脂率 \(format(fat))%(\(dayString(latest.date, calendar: calendar)))")
        }
        if let target = goal.targetBodyFatPercent { lines.append("目标体脂率 \(format(target))%") }
        if let week = change(entries, days: 7, now: now, calendar: calendar) {
            lines.append("最近 7 天体重变化 \(signed(week)) 公斤")
        }
        if let month = change(entries, days: 30, now: now, calendar: calendar) {
            lines.append("最近 30 天体重变化 \(signed(month)) 公斤")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 一位小数,整数不带 ".0"。
    public static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    public static func signed(_ value: Double) -> String {
        let text = format(abs(value))
        if text == "0" { return "0" }
        return (value > 0 ? "+" : "-") + text
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// `DeepSeekClient.weightPlan` 的返回:一句简短建议 + 一天的饮食安排。
public struct WeightDietPlan: Codable, Equatable, Sendable {
    public struct Meal: Codable, Equatable, Sendable, Identifiable {
        /// 本地生成,用来记"这一餐建成了哪条任务"。
        public var id: UUID
        /// 早餐/午餐/加餐/晚餐…
        public var meal: String
        /// "HH:mm"
        public var time: String
        /// 吃什么(一句话)。
        public var food: String
        /// 估算热量(千卡),模型没给为 nil。
        public var calories: Int?
        /// 点了「加入任务」建出来的那条任务。
        public var taskUUID: UUID?

        public init(id: UUID = UUID(), meal: String, time: String, food: String,
                    calories: Int? = nil, taskUUID: UUID? = nil) {
            self.id = id
            self.meal = meal
            self.time = time
            self.food = food
            self.calories = calories
            self.taskUUID = taskUUID
        }

        /// 任务标题:「早餐:燕麦牛奶 + 两个水煮蛋」。
        public var taskTitle: String { meal.isEmpty ? food : "\(meal):\(food)" }
    }

    public var advice: String
    public var meals: [Meal]
    /// 这份安排是给哪天的(当天 0 点)。
    public var day: Date

    public init(advice: String, meals: [Meal], day: Date) {
        self.advice = advice
        self.meals = meals
        self.day = day
    }

    public var totalCalories: Int? {
        let known = meals.compactMap(\.calories)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// 某一餐的提醒时刻:安排那天的 HH:mm;已经过了就挪到第二天同一时刻
    /// (建一条一出生就逾期的任务,纠缠提醒会立刻响,不合理)。
    public func remindAt(for meal: Meal, now: Date = .now, calendar: Calendar = .current) -> Date {
        let parts = meal.time.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first.map { min(max($0, 0), 23) } ?? 12
        let minute = parts.count > 1 ? min(max(parts[1], 0), 59) : 0
        let base = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                 of: calendar.startOfDay(for: day)) ?? day
        if base > now { return base }
        let todayAt = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                    of: calendar.startOfDay(for: now)) ?? now
        return todayAt > now ? todayAt : (calendar.date(byAdding: .day, value: 1, to: todayAt) ?? todayAt)
    }

    /// 解析 AI 返回(单测入口)。
    /// `{"advice": "一句话", "meals": [{"meal", "time": "HH:mm", "food", "calories"}]}`
    public static func parse(_ payload: [String: Any], day: Date) -> WeightDietPlan? {
        let advice = (payload["advice"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meals: [Meal] = (payload["meals"] as? [Any] ?? []).compactMap { raw in
            guard let dict = raw as? [String: Any],
                  let food = (dict["food"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !food.isEmpty else { return nil }
            let meal = (dict["meal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let time = normalizedTime(dict["time"] as? String) ?? "12:00"
            // 先限幅再转 Int:模型给个 1e30 直接 Int(...) 会崩。超出一餐合理上限的当没给。
            let value = NutritionEstimate.number(dict["calories"], max: NutritionEstimate.maxCalories)
            return Meal(meal: meal, time: time, food: food, calories: value > 0 ? Int(value.rounded()) : nil)
        }
        guard !advice.isEmpty || !meals.isEmpty else { return nil }
        return WeightDietPlan(advice: advice, meals: Array(meals.sorted { $0.time < $1.time }.prefix(6)),
                              day: day)
    }

    /// "7:30" / "07:30" / "07:30:00" → "07:30";认不出返回 nil。
    static func normalizedTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return String(format: "%02d:%02d", parts[0], parts[1])
    }
}
