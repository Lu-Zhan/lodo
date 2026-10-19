import XCTest
@testable import LodoCore

final class WeightPlanTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func day(_ d: Int, hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour))!
    }

    func testMergePrefersManualRecordOnSameDay() {
        let manual = [WeightEntry(date: day(10), weightKg: 70, bodyFatPercent: 22)]
        let health = [HealthDailyPoint(date: day(10, hour: 0), value: 71),
                      HealthDailyPoint(date: day(11, hour: 0), value: 69.5)]
        let merged = WeightPlan.merge(records: manual, health: health, calendar: calendar)
        XCTAssertEqual(merged.map(\.weightKg), [70, 69.5])
        XCTAssertEqual(merged.map(\.fromHealth), [false, true])
    }

    func testBodyFatOnlyRecordDoesNotHideHealthWeight() {
        let manual = [WeightEntry(date: day(10), weightKg: nil, bodyFatPercent: 22)]
        let health = [HealthDailyPoint(date: day(10, hour: 0), value: 71)]
        let merged = WeightPlan.merge(records: manual, health: health, calendar: calendar)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(WeightPlan.latestWeight(merged)?.weightKg, 71)
        XCTAssertEqual(WeightPlan.latestBodyFat(merged)?.bodyFatPercent, 22)
    }

    func testProgressBothDirections() {
        XCTAssertEqual(WeightPlan.progress(start: 80, current: 75, target: 70), 0.5)
        XCTAssertEqual(WeightPlan.progress(start: 80, current: 82, target: 70), 0)
        XCTAssertEqual(WeightPlan.progress(start: 80, current: 68, target: 70), 1)
        // 增重目标
        XCTAssertEqual(WeightPlan.progress(start: 50, current: 52.5, target: 55), 0.5)
        XCTAssertNil(WeightPlan.progress(start: 50, current: 52, target: nil))
    }

    func testBMIAndBand() {
        let bmi = WeightPlan.bmi(weightKg: 72, heightCm: 175)!
        XCTAssertEqual(bmi, 23.51, accuracy: 0.01)
        XCTAssertEqual(WeightPlan.band(bmi), .normal)
        XCTAssertEqual(WeightPlan.band(24), .over)
        XCTAssertEqual(WeightPlan.band(28.1), .obese)
        XCTAssertNil(WeightPlan.bmi(weightKg: 72, heightCm: nil))
    }

    func testChangeNeedsTwoPointsInWindow() {
        let entries = [WeightEntry(date: day(1), weightKg: 75, bodyFatPercent: nil),
                       WeightEntry(date: day(14), weightKg: 74, bodyFatPercent: nil),
                       WeightEntry(date: day(18), weightKg: 73.2, bodyFatPercent: nil)]
        let change = WeightPlan.change(entries, days: 7, now: day(19), calendar: calendar)!
        XCTAssertEqual(change, -0.8, accuracy: 0.001)
        XCTAssertNil(WeightPlan.change(entries, days: 2, now: day(19), calendar: calendar))
    }

    func testComposition() {
        let c = WeightPlan.composition(weightKg: 80, bodyFatPercent: 25)!
        XCTAssertEqual(c.fat, 20)
        XCTAssertEqual(c.lean, 60)
        XCTAssertNil(WeightPlan.composition(weightKg: 80, bodyFatPercent: nil))
    }

    func testPromptSummary() {
        let entries = [WeightEntry(date: day(12), weightKg: 75, bodyFatPercent: 24),
                       WeightEntry(date: day(18), weightKg: 74.5, bodyFatPercent: nil)]
        let goal = WeightGoal(heightCm: 175, targetWeightKg: 70, targetBodyFatPercent: 18)
        let text = WeightPlan.promptSummary(entries: entries, goal: goal, now: day(19), calendar: calendar)!
        XCTAssertTrue(text.contains("当前体重 74.5 公斤(2026-10-18)"))
        XCTAssertTrue(text.contains("目标体重 70 公斤"))
        XCTAssertTrue(text.contains("当前体脂率 24%"))
        XCTAssertTrue(text.contains("最近 7 天体重变化 -0.5 公斤"))
        XCTAssertNil(WeightPlan.promptSummary(entries: [], goal: WeightGoal(), calendar: calendar))
    }

    func testGoalRoundTrip() {
        let goal = WeightGoal(heightCm: 170, targetWeightKg: 62.5)
        XCTAssertEqual(WeightGoal.decode(goal.encoded), goal)
        XCTAssertEqual(WeightGoal().encoded, "")
        XCTAssertTrue(WeightGoal.decode("").isEmpty)
    }

    func testParseDietPlan() {
        let payload: [String: Any] = [
            "advice": "  晚饭主食减半,饭后散步 20 分钟 ",
            "meals": [
                ["meal": "晚餐", "time": "18:30", "food": "清蒸鱼 + 青菜 + 半碗米饭", "calories": 550],
                ["meal": "早餐", "time": "7:30", "food": "燕麦牛奶 + 两个水煮蛋", "calories": "400 千卡"],
                ["meal": "加餐", "time": "bad", "food": "一个苹果"],
                ["meal": "空的", "time": "12:00", "food": "  "],
            ],
        ]
        let plan = WeightDietPlan.parse(payload, day: day(19, hour: 0))!
        XCTAssertEqual(plan.advice, "晚饭主食减半,饭后散步 20 分钟")
        XCTAssertEqual(plan.meals.map(\.time), ["07:30", "12:00", "18:30"])
        XCTAssertEqual(plan.meals.first?.calories, 400)
        XCTAssertNil(plan.meals[1].calories)
        XCTAssertEqual(plan.totalCalories, 950)
        XCTAssertEqual(plan.meals.first?.taskTitle, "早餐:燕麦牛奶 + 两个水煮蛋")
        XCTAssertNil(WeightDietPlan.parse(["advice": "", "meals": []], day: day(19)))
    }

    func testRemindAtMovesPassedMealToTomorrow() {
        let plan = WeightDietPlan(advice: "", meals: [
            .init(meal: "早餐", time: "07:30", food: "a"),
            .init(meal: "晚餐", time: "18:30", food: "b"),
        ], day: day(19, hour: 0))
        let now = day(19, hour: 12)
        XCTAssertEqual(plan.remindAt(for: plan.meals[1], now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18, minute: 30)))
        XCTAssertEqual(plan.remindAt(for: plan.meals[0], now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7, minute: 30)))
    }
}

final class NutritionTests: XCTestCase {
    func testParseSumsItemsOnClient() {
        let payload: [String: Any] = ["items": [
            ["name": "牛肉面", "amount": "1 碗", "calories": 550, "protein": 25, "fat": 15.5, "carbs": 75],
            ["name": "卤蛋", "calories": "80 千卡", "protein": "6.5g", "fat": -1],
            ["name": " ", "calories": 999],
        ], "total": ["calories": 9999]]
        let estimate = NutritionEstimate.parse(payload)!
        XCTAssertEqual(estimate.items.map(\.name), ["牛肉面", "卤蛋"])
        XCTAssertEqual(estimate.items[1].amount, "")
        XCTAssertEqual(estimate.total.calories, 630)
        XCTAssertEqual(estimate.total.proteinG, 31.5)
        XCTAssertEqual(estimate.total.fatG, 15.5)
        XCTAssertNil(NutritionEstimate.parse(["items": []]))
    }

    func testFoodRecordApplyAndTotals() {
        let record = FoodRecord(text: "一杯拿铁")
        XCTAssertEqual(record.nutrition, .zero)
        record.apply(NutritionEstimate(items: [NutritionItem(name: "拿铁", amount: "大杯",
            nutrition: Nutrition(calories: 190, proteinG: 10, fatG: 7, carbsG: 19))]))
        XCTAssertTrue(record.estimated)
        XCTAssertEqual(record.items.first?.amount, "大杯")
        let today = Date()
        let yesterday = today.addingTimeInterval(-86_400 * 1.5)
        let total = FoodPlan.total([(today, record.nutrition), (yesterday, record.nutrition)], on: today)
        XCTAssertEqual(total.calories, 190)
    }

    func testTodaySummaryOnlySendsTotals() {
        let text = FoodPlan.todaySummary(estimatedCount: 1, pendingCount: 1,
                                         intake: Nutrition(calories: 550.4, proteinG: 25), activeEnergy: 320)!
        XCTAssertTrue(text.contains("已记录 1 次进食,估算摄入 550 千卡"))
        XCTAssertTrue(text.contains("另有 1 次进食还没估算出热量"))
        XCTAssertTrue(text.contains("活动消耗 320 千卡"))
        let pendingOnly = FoodPlan.todaySummary(estimatedCount: 0, pendingCount: 2, intake: .zero, activeEnergy: nil)!
        XCTAssertFalse(pendingOnly.contains("0 千卡"))
        XCTAssertNil(FoodPlan.todaySummary(estimatedCount: 0, pendingCount: 0, intake: .zero, activeEnergy: nil))
    }

    func testAbsurdNumbersAreDropped() {
        let estimate = NutritionEstimate.parse(["items": [
            ["name": "怪数", "calories": 1e30, "protein": Double.infinity, "fat": 20],
        ]])!
        XCTAssertEqual(estimate.total.calories, 0)
        XCTAssertEqual(estimate.total.proteinG, 0)
        XCTAssertEqual(estimate.total.fatG, 20)
        let plan = WeightDietPlan.parse(["meals": [["meal": "早餐", "time": "08:00", "food": "x", "calories": 1e30]]],
                                        day: Date())!
        XCTAssertNil(plan.meals.first?.calories)
    }
}
