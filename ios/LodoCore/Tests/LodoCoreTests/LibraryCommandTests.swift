import XCTest
@testable import LodoCore

final class LibraryCommandTests: XCTestCase {
    /// 样例里的行程都在 2026 年 7 月;规划解析会把落在"今天"之前的行程挪到以后,
    /// 所以"今天"固定在那之前,结果不随真实日期变。
    private let planNow = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    private func parseTripPlanAt2026(_ raw: [String: Any]) throws -> TripPlanProposal {
        try DeepSeekClient.parseTripPlan(raw, now: planNow)
    }

    private let assetID = UUID()
    private let feedID = UUID()

    func testCreateAssetParsesAmountsAndCategory() throws {
        let op = try DeepSeekClient.parseAssetOp(
            ["title": "招商银行储蓄", "category": "存款", "value": "320,000", "currency": "cny"],
            action: "create_asset", validIDs: [])
        XCTAssertEqual(op, .create(AssetDraft(title: "招商银行储蓄", category: "存款",
                                              value: 320_000, currency: "CNY")))
    }

    /// 只记了一笔贷款也算资产台账里的一项;名称、金额都没有才报错。
    func testCreateAssetNeedsTitleAndSomeAmount() throws {
        XCTAssertNoThrow(try DeepSeekClient.parseAssetOp(
            ["title": "车贷", "liability": 80000, "interest_rate": 3.5],
            action: "create_asset", validIDs: []))
        XCTAssertThrowsError(try DeepSeekClient.parseAssetOp(
            ["title": "房子"], action: "create_asset", validIDs: []))
    }

    func testUpdateAssetOnlyCarriesMentionedFieldsAndChecksID() throws {
        let op = try DeepSeekClient.parseAssetOp(
            ["id": "[id:\(assetID.uuidString)]", "value": 350000],
            action: "update_asset", validIDs: [assetID.uuidString])
        XCTAssertEqual(op, .update(id: assetID, change: AssetChange(value: 350_000)))
        XCTAssertThrowsError(try DeepSeekClient.parseAssetOp(
            ["id": UUID().uuidString, "value": 1], action: "update_asset",
            validIDs: [assetID.uuidString]))
    }

    /// 一次贴了好几个链接:展开成多条,重复的去掉。
    func testSubscribeFeedExpandsListAndDedupes() throws {
        let ops = try DeepSeekClient.parseFeedOps(
            ["feeds": [["url": "https://a.com/feed"], ["url": "https://A.com/feed"],
                       ["name": "少数派", "kind": "news"], ["url": "https://b.dev", "kind": "blog"]]],
            action: "subscribe_feed", validIDs: [])
        XCTAssertEqual(ops, [
            .subscribe(FeedDraft(url: "https://a.com/feed")),
            .subscribe(FeedDraft(name: "少数派", kind: .news)),
            .subscribe(FeedDraft(url: "https://b.dev", kind: .blog)),
        ])
    }

    func testUpdateFeed() throws {
        let ops = try DeepSeekClient.parseFeedOps(
            ["id": feedID.uuidString, "enabled": false, "title": "HN"],
            action: "update_feed", validIDs: [feedID.uuidString])
        XCTAssertEqual(ops, [.update(id: feedID, change: FeedChange(title: "HN", enabled: false))])
    }

    func testFeedFuzzyMatch() {
        struct Feed { let title: String; let url: String }
        let feeds = [Feed(title: "少数派", url: "https://sspai.com/feed"),
                     Feed(title: "Hacker News", url: "https://hnrss.org/frontpage"),
                     Feed(title: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml")]
        func find(_ query: String) -> String? {
            FeedMatch.best(query, in: feeds, title: \.title, url: \.url)?.title
        }
        XCTAssertEqual(find("hackernews"), "Hacker News")
        XCTAssertEqual(find("少数派的文章"), "少数派")
        XCTAssertEqual(find("bbc"), "BBC 中文")
        XCTAssertEqual(find("sspai"), "少数派")
        XCTAssertNil(find("纽约时报"))
    }

    /// 资产、订阅动作受开关门控,可以和待办写操作同时出现。
    func testParseCommandKeepsLibraryOpsAlongsideTasks() throws {
        let result = try DeepSeekClient.parseCommand(
            ["actions": [
                ["action": "create_asset", "title": "理财", "value": 5000],
                ["action": "subscribe_feed", "url": "https://sspai.com/feed"],
                ["action": "create", "title": "交报告", "remind_at": "2026-07-09 09:00"],
            ]],
            validUUIDs: [], memoryEnabled: false, assetsEnabled: true, feedsEnabled: true)
        guard case .actions(let actions) = result else { return XCTFail() }
        XCTAssertEqual(actions.count, 3)
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            ["actions": [["action": "create_asset", "title": "理财", "value": 5000]]],
            validUUIDs: [], memoryEnabled: false))
    }

    func testTripPlanRecordFlag() throws {
        let plan = try parseTripPlanAt2026([
            "trip": "东京四日", "record": true, "start_date": "2026-10-01", "end_date": "2026-10-04",
            "items": [["kind": "place", "title": "浅草寺", "start": "2026-10-01 10:00"]],
        ])
        XCTAssertEqual(plan.recorded, true)
    }
}
