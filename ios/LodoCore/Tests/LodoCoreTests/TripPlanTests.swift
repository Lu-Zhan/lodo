import XCTest
@testable import LodoCore

/// 「规划行程」(plan_trip)的解析与快照单测,不发请求。
final class TripPlanTests: XCTestCase {
    let calendar = Calendar.current

    private func date(day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private var samplePlan: [String: Any] {
        [
            "action": "plan_trip",
            "trip": "京都三日",
            "start_date": "2026-07-08",
            "end_date": "2026-07-10",
            "summary": "东山、岚山、伏见各一天。",
            "items": [
                ["kind": "lodging", "title": "住四条河原町一带",
                 "start": "2026-07-08 15:00", "end": "2026-07-10 11:00", "place": "四条河原町"],
                ["kind": "place", "title": "清水寺", "start": "2026-07-08 16:00",
                 "end": "2026-07-08 17:30", "place": "清水寺", "note": "从五条坂上去。",
                 "price": 500, "currency": "jpy"],
                // 航班编不出来,就算模型给了也丢掉。
                ["kind": "flight", "title": "CA927", "start": "2026-07-08 09:00"],
                // 缺标题、类型不认识的都跳过,不让整份规划失败。
                ["kind": "place", "start": "2026-07-09 09:00"],
                ["kind": "restaurant", "title": "锦市场"],
                // end 早于 start:丢掉 end,保留这一条。
                ["kind": "place", "title": "伏见稻荷大社", "start": "2026-07-10 08:00",
                 "end": "2026-07-10 07:00", "price": "0"],
            ] as [[String: Any]],
        ]
    }

    func testParsePlanTripAction() throws {
        let result = try DeepSeekClient.parseCommand(
            ["actions": [samplePlan]], validUUIDs: [], memoryEnabled: false,
            tripPlanEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .planTrip(let plan) = actions[0] else {
            return XCTFail("expected a single planTrip action")
        }
        XCTAssertEqual(plan.tripTitle, "京都三日")
        XCTAssertEqual(plan.summary, "东山、岚山、伏见各一天。")
        XCTAssertEqual(plan.startDate, date(day: 8))
        XCTAssertEqual(plan.endDate, date(day: 10))
        XCTAssertEqual(plan.items.map(\.title), ["住四条河原町一带", "清水寺", "伏见稻荷大社"])
        XCTAssertEqual(plan.items[0].kind, .lodging)
        XCTAssertEqual(plan.items[1].start, date(day: 8, hour: 16))
        XCTAssertEqual(plan.items[1].placeName, "清水寺")
        XCTAssertEqual(plan.items[1].note, "从五条坂上去。")
        XCTAssertEqual(plan.items[1].price, 500)
        XCTAssertEqual(plan.items[1].currency, "JPY")
        XCTAssertNil(plan.items[2].end)
        XCTAssertEqual(plan.items[2].price, 0)
        XCTAssertNil(plan.appliedTripUUID)
        XCTAssertFalse(plan.isApplied)
    }

    /// 开关没开(Watch 等调用方)时,模型幻觉出 plan_trip 也不认。
    func testPlanTripIgnoredWhenDisabled() {
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            ["actions": [samplePlan]], validUUIDs: [], memoryEnabled: false))
    }

    /// plan_trip 和写操作混在一起时丢掉规划、只留写操作(和 answer/suggest_memorize 同组)。
    func testPlanTripDroppedWhenMixedWithWrites() throws {
        let create: [String: Any] = ["action": "create", "title": "订机票",
                                     "remind_at": "2026-07-08 20:00"]
        let result = try DeepSeekClient.parseCommand(
            ["actions": [samplePlan, create]], validUUIDs: [], memoryEnabled: false,
            tripPlanEnabled: true)
        guard case .actions(let actions) = result else { return XCTFail() }
        XCTAssertEqual(actions.count, 1)
        guard case .create = actions[0] else { return XCTFail("expected create") }
    }

    /// 没给起止日时从安排的时间里推。
    func testDatesInferredFromItems() throws {
        let plan = try DeepSeekClient.parseTripPlan([
            "trip": "大阪",
            "items": [
                ["kind": "place", "title": "大阪城", "start": "2026-07-09 10:00"],
                ["kind": "place", "title": "道顿堀", "start": "2026-07-11 18:00",
                 "end": "2026-07-11 21:00"],
            ],
        ])
        XCTAssertEqual(plan.startDate, date(day: 9, hour: 10))
        XCTAssertEqual(plan.endDate, date(day: 11, hour: 21))
        XCTAssertEqual(plan.days().count, 3)
    }

    func testMissingTitleFallsBackAndReversedDatesSwap() throws {
        let plan = try DeepSeekClient.parseTripPlan([
            "start_date": "2026-07-10", "end_date": "2026-07-08",
            "items": [["kind": "place", "title": "清水寺", "start": "2026-07-08 16:00"]],
        ])
        XCTAssertEqual(plan.tripTitle, "旅行规划")
        XCTAssertEqual(plan.startDate, date(day: 8))
        XCTAssertEqual(plan.endDate, date(day: 10))
    }

    func testRejectsPlanWithoutUsableItemsOrDates() {
        // 只有航班:没有一条能写的安排。
        XCTAssertThrowsError(try DeepSeekClient.parseTripPlan([
            "trip": "东京", "start_date": "2026-07-08",
            "items": [["kind": "flight", "title": "CA167", "start": "2026-07-08 09:00"]],
        ]))
        // 安排都没时间、也没给起止日:推不出是哪几天。
        XCTAssertThrowsError(try DeepSeekClient.parseTripPlan([
            "trip": "东京", "items": [["kind": "place", "title": "浅草寺"]],
        ]))
    }

    /// 快照能按天分组复用 TravelPlan,且序列化往返不丢写入状态;老消息缺写入字段也能解。
    func testSnapshotGroupingAndCodable() throws {
        var plan = try DeepSeekClient.parseTripPlan(samplePlan)
        let grouped = TravelPlan.group(plan.entries, into: plan.days())
        XCTAssertEqual(grouped.count, 3)
        // 住宿按住的每一晚铺开:8、9 号两晚。
        XCTAssertEqual(grouped[0].entries.map(\.title), ["住四条河原町一带", "清水寺"])
        XCTAssertEqual(grouped[1].entries.map(\.title), ["住四条河原町一带"])
        XCTAssertEqual(grouped[2].entries.map(\.title), ["伏见稻荷大社"])
        // id 稳定:两次取 entries 一致。
        XCTAssertEqual(plan.entries.map(\.id), plan.entries.map(\.id))

        plan.appliedTripUUID = UUID()
        plan.appliedItemUUIDs = [UUID(), UUID()]
        plan.createdTrip = true
        let decoded = try JSONDecoder().decode(
            TripPlanProposal.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertTrue(decoded.isApplied)

        var reverted = decoded
        reverted.reverted = true
        XCTAssertFalse(reverted.isApplied)

        let legacy = try JSONEncoder().encode(TripPlanProposal(
            tripTitle: "旧", startDate: date(day: 8), endDate: date(day: 8), items: []))
        let old = try JSONDecoder().decode(TripPlanProposal.self, from: legacy)
        XCTAssertNil(old.appliedTripUUID)
        XCTAssertNil(old.reverted)
    }

    // MARK: - edit_trip

    func testParseEditTrip() throws {
        let keep = UUID(), drop = UUID(), both = UUID()
        let result = try DeepSeekClient.parseCommand(
            ["actions": [[
                "action": "edit_trip", "trip": "京都三日", "summary": "第二天改去奈良",
                // 抄回来带 [id:] 前缀的也认;重复的去重;乱写的丢掉。
                "remove": ["[id:\(drop.uuidString)]", drop.uuidString, "天龙寺", both.uuidString],
                "add": [
                    ["kind": "place", "title": "东大寺", "start": "2026-07-09 10:00"],
                    ["kind": "flight", "title": "CA927", "start": "2026-07-09 09:00"],
                ],
                "update": [
                    ["id": keep.uuidString, "start": "2026-07-09 15:00", "place": "奈良公园"],
                    // 什么都没改的 update 丢掉。
                    ["id": UUID().uuidString],
                    // 既删又改:以删为准。
                    ["id": both.uuidString, "title": "改名"],
                ],
            ] as [String: Any]]],
            validUUIDs: [], memoryEnabled: false, travelEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .editTrip(let edit) = actions[0] else {
            return XCTFail("expected a single editTrip action")
        }
        XCTAssertEqual(edit.tripTitle, "京都三日")
        XCTAssertEqual(edit.summary, "第二天改去奈良")
        XCTAssertEqual(edit.removeIDs, [drop, both])
        XCTAssertEqual(edit.additions.map(\.title), ["东大寺"])
        XCTAssertEqual(edit.additions[0].start, date(day: 9, hour: 10))
        XCTAssertEqual(edit.updates.count, 1)
        XCTAssertEqual(edit.updates[0].id, keep)
        XCTAssertEqual(edit.updates[0].start, date(day: 9, hour: 15))
        XCTAssertEqual(edit.updates[0].placeName, "奈良公园")
        XCTAssertNil(edit.updates[0].title)
        XCTAssertEqual(edit.referencedIDs, [drop, both, keep])
    }

    /// 模型漏了外面那层 actions 数组,把单条操作直接摊在顶层:当成一条操作处理,
    /// 不报"缺少 actions"。
    func testBareTopLevelActionIsWrapped() throws {
        let drop = UUID()
        let result = try DeepSeekClient.parseCommand(
            ["action": "edit_trip", "trip": "北海道", "summary": "按酒店位置重排",
             "remove": [drop.uuidString]],
            validUUIDs: [], memoryEnabled: false, travelEnabled: true)
        guard case .actions(let actions) = result, actions.count == 1,
              case .editTrip(let edit) = actions[0] else {
            return XCTFail("expected a single editTrip action")
        }
        XCTAssertEqual(edit.tripTitle, "北海道")
        XCTAssertEqual(edit.removeIDs, [drop])
    }

    /// 反过来:模型把 ReAct 工具塞进了 actions 数组,仍按工具调用处理,
    /// 不撞上"未知 action"(读行程这一步走不通的话,整条调整行程的请求就废了)。
    func testToolCallInsideActionsIsAccepted() throws {
        let result = try DeepSeekClient.parseCommand(
            ["actions": [["action": "read_trip", "thought": "先看行程", "name": "北海道"]]],
            validUUIDs: [], memoryEnabled: false, travelEnabled: true)
        guard case .toolCall(let thought, .readTrip(let name)) = result else {
            return XCTFail("expected a readTrip tool call")
        }
        XCTAssertEqual(thought, "先看行程")
        XCTAssertEqual(name, "北海道")
    }

    /// 但对应能力没开时不认:travelEnabled == false 时 read_trip 仍是未知 action。
    func testToolCallInsideActionsRespectsCapability() {
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            ["actions": [["action": "read_trip", "name": "北海道"]]],
            validUUIDs: [], memoryEnabled: false, travelEnabled: false))
    }

    /// 没有旅行(travelEnabled == false)时模型幻觉出 edit_trip 也不认。
    func testEditTripIgnoredWhenTravelDisabled() {
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            ["actions": [["action": "edit_trip", "remove": [UUID().uuidString]]]],
            validUUIDs: [], memoryEnabled: false, tripPlanEnabled: true))
    }

    func testEditTripWithoutChangesThrows() {
        XCTAssertThrowsError(try DeepSeekClient.parseTripEdit([
            "trip": "京都三日", "remove": ["不是 uuid"],
            "add": [["kind": "flight", "title": "CA927"]], "update": [],
        ]))
    }

    /// read_trip 喂给 AI 时带 id,edit_trip 才能引用;规划卡片那份不带。
    func testPromptSummaryIncludesIDsOnlyWhenAsked() {
        let id = UUID()
        let entry = TravelEntry(id: id, kind: .place, title: "清水寺", start: date(day: 8, hour: 16))
        let days = [date(day: 8)]
        XCTAssertTrue(TravelPlan.promptSummary(tripTitle: "京都", days: days, entries: [entry],
                                               includeIDs: true)
            .contains("清水寺 · 16:00 [id:\(id.uuidString)]"))
        XCTAssertFalse(TravelPlan.promptSummary(tripTitle: "京都", days: days, entries: [entry])
            .contains("[id:"))
    }

    func testEditRecordTranscriptAndCodable() throws {
        var record = TripEditRecord(
            tripUUID: UUID(), tripTitle: "京都三日", summary: "第二天改去奈良",
            added: [TripEditLine(id: UUID(), kind: .place, title: "东大寺", start: date(day: 9, hour: 10))],
            removed: [BackupMemoryItem(
                uuid: UUID(), kindRaw: "text", title: "天龙寺", summary: "", tags: ["旅行"],
                sourceText: "", urlString: nil, originalFileName: nil, relativeFilePath: nil,
                statusRaw: "ready", createdAt: date(day: 1), travelKindRaw: "place",
                travelStart: date(day: 9, hour: 9, minute: 30))],
            skipped: ["CA927(航班)"])
        XCTAssertTrue(record.hasChanges)
        XCTAssertEqual(record.transcript, """
            已调整「京都三日」:第二天改去奈良
            删除:天龙寺(7月9日 09:30)
            新增:东大寺(7月9日 10:00)
            没有改动:CA927(航班)
            """)
        record.reverted = true
        let decoded = try JSONDecoder().decode(TripEditRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.removed.first?.title, "天龙寺")
        XCTAssertEqual(decoded.added, record.added)
        XCTAssertEqual(decoded.reverted, true)
        XCTAssertTrue(decoded.transcript.hasSuffix("(这次调整已撤销)"))
        XCTAssertFalse(TripEditRecord(tripUUID: UUID(), tripTitle: "x", summary: "").hasChanges)
    }

    func testTravelSkillMentionsEditTrip() {
        XCTAssertTrue(AgentSkillStore.defaultContent(for: .travel).contains("edit_trip"))
    }

    func testTripPlannerSkillIsRegistered() {
        XCTAssertTrue(AgentSkillID.allCases.contains(.tripPlanner))
        XCTAssertTrue(AgentSkillStore.defaultContent(for: .tripPlanner).contains("plan_trip"))
    }
}
