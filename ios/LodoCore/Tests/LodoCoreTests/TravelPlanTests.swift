import XCTest
@testable import LodoCore

/// 旅行纯逻辑单测(不碰 SwiftData 上下文、不需要模拟器)。
/// 基准时间沿用 SchedulerTests 的 2026-07-08 09:00(周三)。
final class TravelPlanTests: XCTestCase {
    let calendar = Calendar.current

    private func date(day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }

    private func entry(
        _ kind: TravelItemKind, _ title: String, start: Date? = nil, end: Date? = nil,
        price: Double? = nil, currency: String = "CNY", place: String? = nil,
        origin: String? = nil, code: String? = nil
    ) -> TravelEntry {
        TravelEntry(id: UUID(), kind: kind, title: title, start: start, end: end,
                    price: price, currency: currency, placeName: place,
                    originName: origin, code: code)
    }

    /// 7/8 – 7/11,四天。
    private var days: [Date] { (8...11).map { date(day: $0) } }

    // MARK: - 按天分组

    func testFlightAndPlaceLandOnTheirStartDay() {
        let flight = entry(.flight, "国航 CA123", start: date(day: 8, hour: 9))
        let place = entry(.place, "浅草寺", start: date(day: 10, hour: 14))
        let grouped = TravelPlan.group([flight, place], into: days)
        XCTAssertEqual(grouped.count, 4)
        XCTAssertEqual(grouped[0].entries.map(\.title), ["国航 CA123"])
        XCTAssertTrue(grouped[1].entries.isEmpty)
        XCTAssertEqual(grouped[2].entries.map(\.title), ["浅草寺"])
        XCTAssertTrue(grouped[3].entries.isEmpty)
    }

    /// 住宿按"住了几晚"铺开:7/8 入住、7/11 退房 = 8/9/10 三晚,退房当天不算。
    func testLodgingSpansEveryNight() {
        let hotel = entry(.lodging, "新宿王子", start: date(day: 8, hour: 15), end: date(day: 11, hour: 11))
        let grouped = TravelPlan.group([hotel], into: days)
        XCTAssertEqual(grouped.map { $0.entries.count }, [1, 1, 1, 0])
    }

    /// 没填退房时间的住宿只出现在入住那天,不会无限铺下去。
    func testLodgingWithoutEndOnlyOnStartDay() {
        let hotel = entry(.lodging, "民宿", start: date(day: 9, hour: 15))
        XCTAssertEqual(TravelPlan.group([hotel], into: days).map { $0.entries.count }, [0, 1, 0, 0])
    }

    /// 当天往返(入住/退房同一天)仍然算这一天。
    func testLodgingSameDayCountsOnce() {
        let hotel = entry(.lodging, "过境酒店",
                          start: date(day: 9, hour: 2), end: date(day: 9, hour: 10))
        XCTAssertEqual(TravelPlan.group([hotel], into: days).map { $0.entries.count }, [0, 1, 0, 0])
    }

    func testEntriesSortedByTimeWithinDay() {
        let noon = entry(.place, "午餐", start: date(day: 9, hour: 12))
        let morning = entry(.place, "筑地市场", start: date(day: 9, hour: 8))
        let grouped = TravelPlan.group([noon, morning], into: days)
        XCTAssertEqual(grouped[1].entries.map(\.title), ["筑地市场", "午餐"])
    }

    // MARK: - 未排期 / 超出范围

    func testUnscheduledEntriesAreSeparated() {
        let wish = entry(.place, "台场")
        let flight = entry(.flight, "CA123", start: date(day: 8, hour: 9))
        XCTAssertTrue(TravelPlan.group([wish, flight], into: days).allSatisfy {
            !$0.entries.contains(wish)
        })
        XCTAssertEqual(TravelPlan.unscheduled([wish, flight]).map(\.title), ["台场"])
    }

    /// 有时间但落在行程区间外的项不能凭空消失(改签、记错日期)。
    func testOutOfRangeEntriesAreKept() {
        let early = entry(.flight, "提前到的航班", start: date(day: 5, hour: 9))
        let inside = entry(.place, "浅草寺", start: date(day: 10, hour: 14))
        let wish = entry(.place, "没定时间的")
        let extras = TravelPlan.outOfRange([early, inside, wish], days: days)
        XCTAssertEqual(extras.map(\.title), ["提前到的航班"])
    }

    // MARK: - 价格

    func testCostsGroupedByCurrencyDescending() {
        let entries = [
            entry(.flight, "去程", price: 3200, currency: "CNY"),
            entry(.flight, "回程", price: 2800, currency: "CNY"),
            entry(.lodging, "酒店", price: 48000, currency: "JPY"),
            entry(.place, "免费的公园", price: nil),
            entry(.place, "零元项", price: 0),
        ]
        XCTAssertEqual(TravelPlan.costs(entries), [
            TravelCostLine(currency: "JPY", amount: 48000),
            TravelCostLine(currency: "CNY", amount: 6000),
        ])
    }

    func testCostsByKind() {
        let entries = [
            entry(.flight, "去程", price: 3200),
            entry(.lodging, "酒店", price: 1500),
        ]
        XCTAssertEqual(TravelPlan.costs(entries, kind: .flight),
                       [TravelCostLine(currency: "CNY", amount: 3200)])
    }

    /// 换不出汇率的币种不参与求和,而是原样报回去——宁可少算也不拿错汇率糊弄。
    func testTotalReportsMissingRatesInsteadOfSwallowingThem() {
        let entries = [
            entry(.flight, "去程", price: 1000, currency: "CNY"),
            entry(.lodging, "酒店", price: 100, currency: "USD"),
            entry(.place, "门票", price: 5000, currency: "JPY"),
        ]
        let total = TravelPlan.total(entries, in: "CNY") { amount, from, to in
            guard from == "USD", to == "CNY" else { return nil }
            return amount * 7
        }
        XCTAssertEqual(total.amount, 1700, accuracy: 0.001)
        XCTAssertEqual(total.missingCurrencies, ["JPY"])
    }

    func testTotalWithNoPricesIsZero() {
        let total = TravelPlan.total([entry(.place, "免费")], in: "CNY") { _, _, _ in nil }
        XCTAssertEqual(total.amount, 0, accuracy: 0.001)
        XCTAssertTrue(total.missingCurrencies.isEmpty)
    }

    // MARK: - 喂给 AI 的摘要

    func testPromptSummaryIncludesDaysPricesAndPending() {
        let entries = [
            entry(.flight, "国航 CA123", start: date(day: 8, hour: 9), end: date(day: 8, hour: 14),
                  price: 3200, place: "东京", origin: "北京", code: "CA123"),
            entry(.lodging, "新宿王子", start: date(day: 8, hour: 15), end: date(day: 11, hour: 11),
                  price: 48000, currency: "JPY", place: "新宿"),
            entry(.place, "台场"),
        ]
        let text = TravelPlan.promptSummary(tripTitle: "东京四日", days: days, entries: entries)
        XCTAssertTrue(text.hasPrefix("「东京四日」行程:"))
        XCTAssertTrue(text.contains("7月8日"))
        XCTAssertTrue(text.contains("航班:国航 CA123"))
        XCTAssertTrue(text.contains("北京 → 东京"))
        XCTAssertTrue(text.contains("09:00–14:00"))
        XCTAssertTrue(text.contains("未排期:"))
        XCTAssertTrue(text.contains("台场"))
        XCTAssertTrue(text.contains("花费合计:"))
        XCTAssertTrue(text.contains("JPY 48000.00"))
    }

    func testPromptSummaryOfEmptyTrip() {
        XCTAssertEqual(TravelPlan.promptSummary(tripTitle: "空行程", days: days, entries: []),
                       "「空行程」还没有任何行程项。")
    }

    // MARK: - 订单解析(parseTravelPayload)

    func testParseTravelPayload() throws {
        let items = try DeepSeekClient.parseTravelPayload(["items": [
            ["kind": "flight", "title": "国航 CA123", "code": "CA123",
             "start": "2026-07-08 09:00", "end": "2026-07-08 14:00",
             "origin": "北京", "place": "东京", "price": 3200, "currency": "CNY"],
            ["kind": "lodging", "title": "新宿王子",
             "start": "2026-07-08 15:00", "end": "2026-07-11 11:00",
             "place": "新宿", "price": 48000, "currency": "JPY", "note": "含早"],
        ]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .flight)
        XCTAssertEqual(items[0].originName, "北京")
        XCTAssertEqual(items[0].start, date(day: 8, hour: 9))
        XCTAssertEqual(items[1].kind, .lodging)
        XCTAssertEqual(items[1].price, 48000)
        XCTAssertEqual(items[1].note, "含早")
    }

    /// 单条解析不出来就跳过那条,不让整份订单白费。
    func testParseTravelPayloadSkipsBadItems() throws {
        let items = try DeepSeekClient.parseTravelPayload(["items": [
            ["kind": "spaceship", "title": "不认识的类型"],
            ["kind": "place", "title": "  "],
            ["kind": "place"],
            ["kind": "place", "title": "浅草寺"],
        ]])
        XCTAssertEqual(items.map(\.title), ["浅草寺"])
    }

    /// 日期格式不对时只丢时间,条目本身留着(用户可以自己补)。
    func testParseTravelPayloadKeepsItemWhenDateUnparsable() throws {
        let items = try DeepSeekClient.parseTravelPayload(["items": [
            ["kind": "flight", "title": "CA123", "start": "七月八号早上"],
        ]])
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].start)
    }

    /// 币种统一大写,否则 "jpy" 和 "JPY" 会在价格汇总里分成两组。
    func testParseTravelPayloadUppercasesCurrency() throws {
        let items = try DeepSeekClient.parseTravelPayload(["items": [
            ["kind": "place", "title": "门票", "price": "1200", "currency": "jpy"],
        ]])
        XCTAssertEqual(items[0].currency, "JPY")
        XCTAssertEqual(items[0].price, 1200)
    }

    /// 登机牌/航班动态截图里的补充信息解析进 flight;非航班条目即使带了也丢掉。
    func testParseTravelPayloadFlightDetails() throws {
        let items = try DeepSeekClient.parseTravelPayload(["items": [
            ["kind": "flight", "title": "国航 CA123", "code": "CA123",
             "start": "2026-07-08 09:00",
             "flight": ["airline": "中国国际航空", "departure_code": "pek", "departure_terminal": "T3",
                        "check_in_counter": "F01-F12", "gate": 23, "seat": " 32A ",
                        "boarding_time": "2026-07-08 08:20",
                        "estimated_departure": "2026-07-08 09:40",
                        "status": "DELAYED", "cabin": ""]],
            ["kind": "flight", "title": "只有基本信息", "flight": ["status": "flying"]],
            ["kind": "place", "title": "浅草寺", "flight": ["gate": "E1"]],
        ]])
        let flight = try XCTUnwrap(items[0].flight)
        XCTAssertEqual(flight.departureCode, "PEK")
        XCTAssertEqual(flight.gate, "23", "数字形式的登机口转成字符串")
        XCTAssertEqual(flight.seat, "32A")
        XCTAssertNil(flight.cabin, "空串当没有")
        XCTAssertEqual(flight.status, .delayed)
        XCTAssertEqual(flight.boardingTime, date(day: 8, hour: 8).addingTimeInterval(20 * 60))
        XCTAssertEqual(flight.departureDelayMinutes(planned: items[0].start), 40)
        XCTAssertNil(items[1].flight, "认不出的状态丢掉,剩下一个字段都没有就是 nil")
        XCTAssertNil(items[2].flight)
    }

    /// 再导入一张新截图:有的字段覆盖,没有的保留。
    func testFlightDetailsMerge() {
        let old = FlightDetails(departureTerminal: "T3", gate: "E23", seat: "32A",
                                status: .scheduled, updatedAt: date(day: 7, hour: 20))
        let newer = FlightDetails(gate: "E30", status: .boarding, updatedAt: date(day: 8, hour: 8))
        let merged = old.merged(with: newer)
        XCTAssertEqual(merged.gate, "E30")
        XCTAssertEqual(merged.seat, "32A")
        XCTAssertEqual(merged.departureTerminal, "T3")
        XCTAssertEqual(merged.status, .boarding)
        XCTAssertEqual(merged.updatedAt, date(day: 8, hour: 8))
    }

    func testFlightDetailsCodingAndHelpers() throws {
        let details = FlightDetails(gate: "E23", status: .boarding, updatedAt: date(day: 8, hour: 8))
        let data = try XCTUnwrap(FlightDetails.encode(details))
        XCTAssertEqual(FlightDetails.decode(data), details)
        XCTAssertNil(FlightDetails.decode(Data("坏数据".utf8)))
        XCTAssertNil(FlightDetails.encode(FlightDetails(updatedAt: Date())), "空信息不落库")
        XCTAssertEqual(FlightDetails.normalizedNumber(" ca-981 "), "CA981")
        XCTAssertNil(FlightDetails(estimatedDeparture: date(day: 8, hour: 8))
            .departureDelayMinutes(planned: date(day: 8, hour: 9)), "提前不算晚点")
    }

    /// read_trip 摘要带上航班补充信息。
    func testPromptSummaryIncludesFlightDetails() {
        let entry = TravelEntry(
            id: UUID(), kind: .flight, title: "国航", start: date(day: 8, hour: 9), code: "CA123",
            flight: FlightDetails(departureTerminal: "T3", gate: "E23", seat: "32A", status: .delayed))
        let text = TravelPlan.promptSummary(tripTitle: "东京四日", days: days, entries: [entry])
        XCTAssertTrue(text.contains("状态 延误"), text)
        XCTAssertTrue(text.contains("登机口 E23"), text)
        XCTAssertTrue(text.contains("座位 32A"), text)
    }

    func testParseTravelPayloadEmptyAndMissing() throws {
        XCTAssertTrue(try DeepSeekClient.parseTravelPayload(["items": []]).isEmpty)
        XCTAssertThrowsError(try DeepSeekClient.parseTravelPayload(["foo": 1]))
    }

    // MARK: - read_trip 工具解析

    func testToolCallReadTrip() throws {
        let result = try DeepSeekClient.parseCommand(
            ["thought": "要看行程", "tool": "read_trip", "name": "东京四日"],
            validUUIDs: [], memoryEnabled: false, travelEnabled: true)
        guard case .toolCall(let thought, .readTrip(let name)) = result else {
            XCTFail("expected toolCall(.readTrip)")
            return
        }
        XCTAssertEqual(thought, "要看行程")
        XCTAssertEqual(name, "东京四日")
    }

    /// name 缺省 = "当前/最近那次旅行",不算错。
    func testToolCallReadTripWithoutNameIsAllowed() throws {
        let result = try DeepSeekClient.parseCommand(
            ["tool": "read_trip"], validUUIDs: [], memoryEnabled: false, travelEnabled: true)
        guard case .toolCall(_, .readTrip(let name)) = result else {
            XCTFail("expected toolCall(.readTrip)")
            return
        }
        XCTAssertEqual(name, "")
    }

    /// travelEnabled == false 时 prompt 里没提过这个选项,模型幻觉出来也不认。
    func testToolCallReadTripIgnoredWhenDisabled() {
        XCTAssertThrowsError(try DeepSeekClient.parseCommand(
            ["tool": "read_trip", "name": "x"],
            validUUIDs: [], memoryEnabled: false, travelEnabled: false))
    }

    // MARK: - TravelTrip 本身

    func testTripDayCountAndDays() {
        let trip = TravelTrip(title: "东京", startDate: date(day: 8), endDate: date(day: 11))
        XCTAssertEqual(trip.dayCount, 4)
        XCTAssertEqual(trip.days, days)
    }

    /// 单日游也是 1 天,不是 0 天。
    func testSingleDayTrip() {
        let trip = TravelTrip(title: "一日", startDate: date(day: 8, hour: 9),
                              endDate: date(day: 8, hour: 20))
        XCTAssertEqual(trip.dayCount, 1)
    }

    func testOngoingAndUpcoming() {
        let trip = TravelTrip(title: "东京", startDate: date(day: 8), endDate: date(day: 11))
        XCTAssertTrue(trip.isOngoing(now: date(day: 11, hour: 23)))
        XCTAssertFalse(trip.isOngoing(now: date(day: 12, hour: 1)))
        XCTAssertTrue(trip.isUpcoming(now: date(day: 7, hour: 9)))
        XCTAssertFalse(trip.isUpcoming(now: date(day: 9, hour: 9)))
    }
}
