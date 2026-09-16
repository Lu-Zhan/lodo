import XCTest
@testable import LodoCore

/// 菜单纯逻辑 + `parseMenuPayload` 单测(不碰 SwiftData、不发请求)。
final class MenuPlanTests: XCTestCase {

    private func dish(
        _ original: String, _ translated: String = "", category: String = "",
        price: Double? = nil, selected: Bool = false, index: Int = 0
    ) -> MenuDishEntry {
        MenuDishEntry(id: UUID(), originalName: original, translatedName: translated,
                      category: category, price: price, selected: selected, sortIndex: index)
    }

    // MARK: - 分组

    /// 分类按菜单上第一次出现的顺序排,不按字母重排;没分类的收在最后。
    func testGroupKeepsMenuOrderAndPutsUncategorizedLast() {
        let dishes = [
            dish("お茶", category: "", index: 0),
            dish("枝豆", category: "前菜", index: 1),
            dish("唐揚げ", category: "主菜", index: 2),
            dish("冷奴", category: "前菜", index: 3),
            dish("ビール", category: "饮品", index: 4),
        ]
        let courses = MenuPlan.group(dishes)
        XCTAssertEqual(courses.map(\.category), ["前菜", "主菜", "饮品", ""])
        XCTAssertEqual(courses[0].dishes.map(\.originalName), ["枝豆", "冷奴"])
        XCTAssertEqual(courses[3].dishes.map(\.originalName), ["お茶"])
    }

    func testGroupTrimsCategoryWhitespace() {
        let courses = MenuPlan.group([
            dish("A", category: "前菜", index: 0),
            dish("B", category: " 前菜 ", index: 1),
        ])
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses[0].dishes.count, 2)
    }

    func testSelectedFollowsMenuOrder() {
        let dishes = [
            dish("C", selected: true, index: 2),
            dish("A", selected: true, index: 0),
            dish("B", index: 1),
        ]
        XCTAssertEqual(MenuPlan.selected(dishes).map(\.originalName), ["A", "C"])
    }

    // MARK: - 名称

    func testDisplayNameFallsBackToOriginal() {
        XCTAssertEqual(dish("Pho", "越南河粉").displayName, "越南河粉")
        XCTAssertEqual(dish("Pho").displayName, "Pho")
    }

    /// 菜单本来就是应用内语言时,译名和原名一样,不重复显示原文。
    func testShowsOriginalOnlyWhenDifferent() {
        XCTAssertTrue(dish("Pho", "越南河粉").showsOriginal)
        XCTAssertFalse(dish("宫保鸡丁", "宫保鸡丁").showsOriginal)
        XCTAssertFalse(dish("宫保鸡丁").showsOriginal)
    }

    // MARK: - 价格

    func testTotalIgnoresUnpricedAndIsNilWhenNothingPriced() {
        XCTAssertEqual(MenuPlan.total([dish("A", price: 380), dish("B"), dish("C", price: 520)]), 900)
        XCTAssertEqual(MenuPlan.unpricedCount([dish("A", price: 380), dish("B")]), 1)
        // 一道标价的都没有:返回 nil,不能说成 0。
        XCTAssertNil(MenuPlan.total([dish("A"), dish("B")]))
        XCTAssertNil(MenuPlan.total([]))
    }

    func testPriceTextDropsZeroDecimals() {
        XCTAssertEqual(MenuPlan.priceText(1200, currency: "JPY"), "JPY 1200")
        XCTAssertEqual(MenuPlan.priceText(12.5, currency: "EUR"), "EUR 12.50")
        XCTAssertEqual(MenuPlan.priceText(38, currency: nil), "38")
    }

    // MARK: - 给服务员看

    func testOrderTextPutsOriginalFirst() {
        let text = MenuPlan.orderText([
            dish("親子丼", "鸡肉滑蛋盖饭", price: 1100, selected: true, index: 1),
            dish("枝豆", "盐水毛豆", selected: true, index: 0),
            dish("冷奴", "凉拌豆腐", index: 2),
            dish("宫保鸡丁", "宫保鸡丁", price: 38, selected: true, index: 3),
        ], currency: "JPY")
        XCTAssertEqual(text, "枝豆(盐水毛豆)\n親子丼(鸡肉滑蛋盖饭) · JPY 1100\n宫保鸡丁 · JPY 38")
    }

    func testSearchTextContainsNamesAndRawText() {
        let text = MenuPlan.searchText(
            restaurant: "とりまる",
            dishes: [dish("枝豆", "盐水毛豆", category: "前菜")],
            rawText: "枝豆 380円")
        XCTAssertTrue(text.contains("とりまる"))
        XCTAssertTrue(text.contains("枝豆 · 盐水毛豆 · 前菜"))
        XCTAssertTrue(text.contains("枝豆 380円"))
    }

    func testMatches() {
        let entry = MenuDishEntry(id: UUID(), originalName: "鶏の唐揚げ", translatedName: "日式炸鸡块",
                                  intro: "酱油腌过的鸡腿肉", category: "主菜")
        XCTAssertTrue(entry.matches("炸鸡"))
        XCTAssertTrue(entry.matches("唐揚"))
        XCTAssertTrue(entry.matches("鸡腿"))
        XCTAssertFalse(entry.matches("甜点"))
    }

    // MARK: - parseMenuPayload

    func testParseMenuPayload() throws {
        let payload: [String: Any] = [
            "restaurant": " 居酒屋 とりまる ",
            "language": "日语",
            "currency": "jpy",
            "dishes": [
                ["original": "枝豆", "translated": "盐水毛豆", "category": "前菜",
                 "price": 380, "description": "煮毛豆撒盐。"],
                ["original": "鯖の塩焼き", "translated": "盐烤青花鱼", "price": 950.5],
                // 价格写成带符号的串也要能读出来。
                ["original": "親子丼", "price": "¥1,100"],
                // 没有原文但有译名:用译名兜底,不丢掉这道菜。
                ["translated": "今日推荐"],
                // 两个名字都没有:跳过这一条,不让整张菜单失败。
                ["price": 500],
            ],
        ]
        let menu = try DeepSeekClient.parseMenuPayload(payload)
        XCTAssertEqual(menu.restaurant, "居酒屋 とりまる")
        XCTAssertEqual(menu.sourceLanguage, "日语")
        XCTAssertEqual(menu.currency, "JPY")
        XCTAssertEqual(menu.dishes.map(\.originalName), ["枝豆", "鯖の塩焼き", "親子丼", "今日推荐"])
        XCTAssertEqual(menu.dishes[0].intro, "煮毛豆撒盐。")
        XCTAssertEqual(menu.dishes[0].category, "前菜")
        XCTAssertEqual(menu.dishes[0].price, 380)
        XCTAssertEqual(menu.dishes[1].price, 950.5)
        XCTAssertEqual(menu.dishes[1].category, "")
        XCTAssertEqual(menu.dishes[2].price, 1100)
        XCTAssertEqual(menu.dishes[2].translatedName, "")
        XCTAssertNil(menu.dishes[3].price)
    }

    func testParseMenuPayloadEmptyAndMissing() throws {
        let empty = try DeepSeekClient.parseMenuPayload(["dishes": [[String: Any]]()])
        XCTAssertTrue(empty.dishes.isEmpty)
        XCTAssertEqual(empty.restaurant, "")
        XCTAssertNil(empty.currency)
        XCTAssertThrowsError(try DeepSeekClient.parseMenuPayload(["items": []]))
    }
}
